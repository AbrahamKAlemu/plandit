"""
Supabase Auth integration.

The iOS app signs in with Supabase (Apple, Google, email) and sends the resulting access
token as `Authorization: Bearer <jwt>`. We verify it locally: new Supabase projects sign
with an asymmetric key published at /auth/v1/.well-known/jwks.json, older projects with
the shared HS256 secret from the dashboard. No call to Supabase per request.
"""

import jwt
from django.conf import settings
from jwt import PyJWKClient, PyJWKClientError, PyJWKSetError
from rest_framework import authentication, exceptions, status

from .activity import sync_profile
from .models import AccountDeletedError, Profile


class AuthUnavailable(exceptions.APIException):
    """The API could not fetch Supabase's signing keys, so it cannot tell whether the token is
    good. 503 rather than 401: the iOS app signs the person out on repeated 401s, and a JWKS
    outage is ours (or Supabase's) to ride out, not theirs."""

    status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    default_detail = "Sign-in check is temporarily unavailable. Try again."
    default_code = "auth_unavailable"


class _JWKClient(PyJWKClient):
    """PyJWKClient whose fetch failures (network, HTTP error, non-JSON body) surface as
    AuthUnavailable. Errors after a successful fetch (unknown `kid`, no signing keys) are left
    alone so they stay 401."""

    def fetch_data(self):
        try:
            return super().fetch_data()
        except (PyJWKClientError, ValueError) as exc:  # ValueError: body is not JSON at all
            raise AuthUnavailable() from exc


_jwks_client: PyJWKClient | None = None


def _jwks() -> PyJWKClient:
    global _jwks_client
    if _jwks_client is None or _jwks_client.uri != settings.SUPABASE_JWKS_URL:
        _jwks_client = _JWKClient(settings.SUPABASE_JWKS_URL, cache_keys=True, lifespan=3600)
    return _jwks_client


def decode_supabase_jwt(token: str) -> dict:
    """Return the verified claims of a Supabase access token or raise AuthenticationFailed."""
    try:
        header = jwt.get_unverified_header(token)
    except jwt.PyJWTError as exc:
        raise exceptions.AuthenticationFailed("Invalid token.") from exc

    algorithm = header.get("alg")
    decode_kwargs = {
        "audience": settings.SUPABASE_JWT_AUDIENCE,
        "options": {"require": ["exp", "sub"]},
    }
    if settings.SUPABASE_JWT_ISSUER:
        decode_kwargs["issuer"] = settings.SUPABASE_JWT_ISSUER

    try:
        if algorithm == "HS256":
            if not settings.SUPABASE_JWT_SECRET:
                raise exceptions.AuthenticationFailed("Server is not configured for HS256 tokens.")
            return jwt.decode(token, settings.SUPABASE_JWT_SECRET, algorithms=["HS256"], **decode_kwargs)
        if algorithm in {"ES256", "RS256"}:
            if not settings.SUPABASE_JWKS_URL:
                raise exceptions.AuthenticationFailed("Server is not configured with SUPABASE_URL.")
            key = _jwks().get_signing_key_from_jwt(token).key
            return jwt.decode(token, key, algorithms=[algorithm], **decode_kwargs)
        raise exceptions.AuthenticationFailed("Unsupported token algorithm.")
    except jwt.ExpiredSignatureError as exc:
        raise exceptions.AuthenticationFailed("Token has expired.") from exc
    except PyJWKSetError as exc:  # JWKS fetched but held no usable keys: upstream is broken, not the token
        raise AuthUnavailable() from exc
    except (jwt.PyJWTError, PyJWKClientError) as exc:
        raise exceptions.AuthenticationFailed("Invalid token.") from exc


class SupabaseJWTAuthentication(authentication.BaseAuthentication):
    keyword = "bearer"

    def authenticate(self, request):
        header = authentication.get_authorization_header(request).decode("utf-8", errors="ignore")
        if not header:
            return None
        parts = header.split()
        if parts[0].lower() != self.keyword:
            return None
        if len(parts) != 2:
            raise exceptions.AuthenticationFailed("Authorization header must be 'Bearer <token>'.")
        claims = decode_supabase_jwt(parts[1])
        try:
            profile = Profile.objects.get_or_create_from_claims(claims)
        except AccountDeletedError as exc:
            raise exceptions.AuthenticationFailed("Account deleted.") from exc
        except ValueError as exc:  # `sub` is not a UUID
            raise exceptions.AuthenticationFailed("Invalid token subject.") from exc
        sync_profile(profile, claims)
        return profile, claims

    def authenticate_header(self, request) -> str:
        return 'Bearer realm="api"'
