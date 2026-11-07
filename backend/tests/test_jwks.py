"""Asymmetric (ES256) tokens are verified against Supabase's JWKS. A JWKS outage must not look
like a bad token: the iOS app signs the person out on repeated 401s.

The fake sits at the urllib opener so PyJWT's real fetch_data runs end to end (HTTP error
handling, JSON decoding, payload validation) and only the network is simulated."""

import io
import json
import urllib.request
import uuid
from datetime import UTC, datetime, timedelta
from urllib.error import HTTPError, URLError

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from django.conf import settings
from jwt.algorithms import ECAlgorithm

from plandit.core import auth

pytestmark = pytest.mark.django_db

KID = "supabase-key-1"


@pytest.fixture
def ec_key():
    return ec.generate_private_key(ec.SECP256R1())


def jwks_for(private_key, kid=KID) -> dict:
    jwk = ECAlgorithm.to_jwk(private_key.public_key(), as_dict=True)
    return {"keys": [{**jwk, "kid": kid, "use": "sig", "alg": "ES256"}]}


def es256_token(private_key, *, kid=KID, expires_in=3600) -> str:
    now = datetime.now(UTC)
    claims = {
        "sub": str(uuid.uuid4()),
        "aud": settings.SUPABASE_JWT_AUDIENCE,
        "iss": settings.SUPABASE_JWT_ISSUER,
        "role": "authenticated",
        "email": "es256@columbia.edu",
        "user_metadata": {"full_name": "Keyed"},
        "app_metadata": {"provider": "email"},
        "is_anonymous": False,
        "iat": now,
        "exp": now + timedelta(seconds=expires_in),
    }
    return jwt.encode(claims, private_key, algorithm="ES256", headers={"kid": kid})


class FakeOpener:
    """What urllib.request.build_opener returns. `outcome` is the JWKS body (dict or raw str)
    or an exception to raise from open()."""

    def __init__(self, outcome, calls):
        self.outcome = outcome
        self.calls = calls

    def open(self, request, timeout=None):
        self.calls.append(request.full_url)
        if isinstance(self.outcome, Exception):
            raise self.outcome
        body = self.outcome if isinstance(self.outcome, str) else json.dumps(self.outcome)
        return io.BytesIO(body.encode("utf-8"))


@pytest.fixture
def jwks_endpoint(monkeypatch):
    monkeypatch.setattr(auth, "_jwks_client", None)  # a fresh client (and key cache) per test

    def install(outcome):
        calls = []
        monkeypatch.setattr(urllib.request, "build_opener", lambda *handlers: FakeOpener(outcome, calls))
        return calls

    return install


def bearer(api_client, token):
    api_client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
    return api_client


def test_es256_token_with_a_known_kid_is_accepted(api_client, ec_key, jwks_endpoint):
    calls = jwks_endpoint(jwks_for(ec_key))
    response = bearer(api_client, es256_token(ec_key)).get("/api/me/")
    assert response.status_code == 200
    assert response.json()["email"] == "es256@columbia.edu"
    assert calls == [settings.SUPABASE_JWKS_URL]


def http_502():
    return HTTPError(settings.SUPABASE_JWKS_URL, 502, "Bad Gateway", {}, io.BytesIO(b"bad gateway"))


@pytest.mark.parametrize(
    "outage",
    [
        URLError("timed out"),  # Supabase unreachable
        TimeoutError("timed out"),
        http_502(),  # Supabase up but failing
        "<html><body>503 Service Unavailable</body></html>",  # an error page instead of JSON
        '["not", "an", "object"]',  # JSON, but not a JWK Set
    ],
)
def test_jwks_outage_is_503_not_401(api_client, ec_key, jwks_endpoint, outage):
    jwks_endpoint(outage)
    response = bearer(api_client, es256_token(ec_key)).get("/api/me/")
    assert response.status_code == 503
    assert response.json() == {"detail": "Sign-in check is temporarily unavailable. Try again."}
    assert "WWW-Authenticate" not in response  # not an auth failure, so the app must not sign out


def test_jwks_without_usable_keys_is_503(api_client, ec_key, jwks_endpoint):
    jwks_endpoint({"keys": [{"kty": "nonsense", "kid": KID}]})
    assert bearer(api_client, es256_token(ec_key)).get("/api/me/").status_code == 503


def test_unknown_kid_in_a_healthy_jwks_is_401(api_client, ec_key, jwks_endpoint):
    other_key = ec.generate_private_key(ec.SECP256R1())
    jwks_endpoint(jwks_for(other_key, kid="some-other-key"))
    response = bearer(api_client, es256_token(ec_key)).get("/api/me/")
    assert response.status_code == 401
    assert response.json()["detail"] == "Invalid token."
    assert response["WWW-Authenticate"].startswith("Bearer")


def test_wrong_signature_against_a_healthy_jwks_is_401(api_client, ec_key, jwks_endpoint):
    other_key = ec.generate_private_key(ec.SECP256R1())
    jwks_endpoint(jwks_for(other_key))  # same kid, different key
    assert bearer(api_client, es256_token(ec_key)).get("/api/me/").status_code == 401


def test_expired_es256_token_is_401(api_client, ec_key, jwks_endpoint):
    jwks_endpoint(jwks_for(ec_key))
    response = bearer(api_client, es256_token(ec_key, expires_in=-60)).get("/api/me/")
    assert response.status_code == 401
    assert response.json()["detail"] == "Token has expired."


def test_outage_after_a_cached_key_does_not_matter(api_client, ec_key, jwks_endpoint):
    # The key is cached on first use; a later outage does not touch requests that use it.
    calls = jwks_endpoint(jwks_for(ec_key))
    client = bearer(api_client, es256_token(ec_key))
    assert client.get("/api/me/").status_code == 200
    jwks_endpoint(URLError("down"))
    assert client.get("/api/me/").status_code == 200
    assert calls == [settings.SUPABASE_JWKS_URL]


def test_auth_unavailable_shape():
    exc = auth.AuthUnavailable()
    assert exc.status_code == 503
    assert exc.default_code == "auth_unavailable"
    assert str(exc.detail) == "Sign-in check is temporarily unavailable. Try again."
