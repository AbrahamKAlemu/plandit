"""
The one call the backend makes to Sign in with Apple's REST API: revoking the person's Apple
tokens when they delete their account (App Store guideline 5.1.1(v)). Needs the team's Sign in
with Apple private key, which never leaves the server.
"""

import logging
import time

import httpx
import jwt
from django.conf import settings

logger = logging.getLogger(__name__)

# Revocation runs after the deletion is committed, inside the request: keep a slow Apple short so
# the person's 204 is not held up (and a killed worker loses nothing but the revocation).
TIMEOUT = httpx.Timeout(4.0, connect=2.0)
TOKEN_URL = "https://appleid.apple.com/auth/token"
REVOKE_URL = "https://appleid.apple.com/auth/revoke"
AUDIENCE = "https://appleid.apple.com"
CLIENT_SECRET_LIFETIME_SECONDS = 300
# Apple's codes are a few hundred characters; anything past this is not a code worth sending.
MAX_CODE_LENGTH = 1024


class AppleSignInError(Exception):
    """Apple could not be reached or refused the request. The message carries the step and the
    HTTP status only: never the code, a token or the client secret."""


def is_configured() -> bool:
    return bool(
        settings.APPLE_TEAM_ID
        and settings.APPLE_CLIENT_ID
        and settings.APPLE_SIGNIN_KEY_ID
        and settings.APPLE_SIGNIN_PRIVATE_KEY
    )


def usable_code(value) -> str | None:
    """The `apple_authorization_code` a client sent, or None when there is nothing worth sending
    to Apple: missing, not a string, blank, implausibly long or not printable ASCII (Apple's codes
    are ASCII; anything else, such as a lone surrogate, could not even be form-encoded). Never a
    validation error, because the person asked to delete their account and revocation is best
    effort."""
    if not isinstance(value, str):
        return None
    code = value.strip()
    if not code or len(code) > MAX_CODE_LENGTH or not (code.isascii() and code.isprintable()):
        return None
    return code


def make_client_secret(now: float | None = None) -> str:
    """The `client_secret` Apple expects: an ES256 JWT signed with the Sign in with Apple key,
    valid for five minutes."""
    issued_at = int(time.time() if now is None else now)
    claims = {
        "iss": settings.APPLE_TEAM_ID,
        "iat": issued_at,
        "exp": issued_at + CLIENT_SECRET_LIFETIME_SECONDS,
        "aud": AUDIENCE,
        "sub": settings.APPLE_CLIENT_ID,
    }
    return jwt.encode(
        claims, settings.APPLE_SIGNIN_PRIVATE_KEY, algorithm="ES256", headers={"kid": settings.APPLE_SIGNIN_KEY_ID}
    )


def revoke_authorization_code(code: str) -> str:
    """Exchange the authorization code the app just obtained for tokens, then revoke them: the
    refresh token when Apple returned one, else the access token. Returns the `token_type_hint`
    that was revoked. Raises AppleSignInError on any failure."""
    client_secret = make_client_secret()
    credentials = {"client_id": settings.APPLE_CLIENT_ID, "client_secret": client_secret}
    response = _post(
        TOKEN_URL, {**credentials, "code": code, "grant_type": "authorization_code"}, step="token exchange"
    )
    try:
        body = response.json()
    except ValueError as exc:
        raise AppleSignInError("Apple token exchange returned a non-JSON body") from exc
    if not isinstance(body, dict):
        raise AppleSignInError("Apple token exchange returned an unexpected body")
    for hint in ("refresh_token", "access_token"):
        token = body.get(hint)
        if isinstance(token, str) and token:
            break
    else:
        raise AppleSignInError("Apple token exchange returned no refresh or access token")
    _post(REVOKE_URL, {**credentials, "token": token, "token_type_hint": hint}, step="revoke")
    return hint


def _post(url: str, data: dict[str, str], *, step: str) -> httpx.Response:
    try:
        response = httpx.post(url, data=data, timeout=TIMEOUT)
    except httpx.HTTPError as exc:
        # The exception's own text names the failure (and at most the URL), not the form data.
        raise AppleSignInError(f"Apple {step} request failed: {exc!r}") from exc
    if not response.is_success:
        raise AppleSignInError(f"Apple {step} returned {response.status_code}")
    return response
