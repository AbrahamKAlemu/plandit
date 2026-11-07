"""
The one Supabase Admin API call the backend makes: deleting an auth user when the person
deletes their account in the app. Needs the service-role key, which never leaves the server.
"""

import logging
import uuid

import httpx
from django.conf import settings

logger = logging.getLogger(__name__)

TIMEOUT_SECONDS = 10.0


class SupabaseAdminError(Exception):
    """The Admin API could not be reached or refused the request."""


def is_configured() -> bool:
    return bool(settings.SUPABASE_SERVICE_ROLE_KEY and settings.SUPABASE_URL)


def _says_user_not_found(response: httpx.Response) -> bool:
    """A GoTrue 404 for a missing user: `{"error_code": "user_not_found", "msg": "User not found"}`
    (older versions use `message`). A 404 from a proxy, a wrong path or a non-JSON body is not."""
    try:
        body = response.json()
    except ValueError:
        return False
    if not isinstance(body, dict):
        return False
    if body.get("error_code") == "user_not_found":
        return True
    text = " ".join(str(body.get(key) or "") for key in ("msg", "message"))
    return "user not found" in text.lower()


def delete_auth_user(user_id: uuid.UUID | str) -> None:
    """Delete the Supabase auth user. A 404 that says the user is already gone counts as
    success; any other non-2xx, any other 404, or a network error raises SupabaseAdminError
    and nothing is deleted."""
    key = settings.SUPABASE_SERVICE_ROLE_KEY
    url = f"{settings.SUPABASE_URL}/auth/v1/admin/users/{user_id}"
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    try:
        response = httpx.delete(url, headers=headers, timeout=TIMEOUT_SECONDS)
    except httpx.HTTPError as exc:
        raise SupabaseAdminError(f"Supabase admin request failed: {exc!r}") from exc
    if response.is_success:
        return
    if response.status_code == 404 and _says_user_not_found(response):
        return
    raise SupabaseAdminError(f"Supabase admin returned {response.status_code}")
