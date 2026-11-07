"""
Refuse to run the test suite against a Supabase (production) database.

pytest creates and drops a `test_*` database on whatever server DATABASE_URL points at. A
`.env` with the production URL must never be used for that. Shared by config.settings_test
(the normal path) and tests/conftest.py (which also runs when DJANGO_SETTINGS_MODULE is
overridden), so the check cannot be skipped by picking a different settings module.
"""

import os
from urllib.parse import urlparse

from django.core.exceptions import ImproperlyConfigured

REMOTE_TEST_DB_OVERRIDE = "PLANDIT_ALLOW_REMOTE_TEST_DB"


def refuse_remote_test_host(host: str | None, environ=os.environ) -> None:
    host = (host or "").lower()
    if "supabase" in host and environ.get(REMOTE_TEST_DB_OVERRIDE) != "1":
        raise ImproperlyConfigured(
            f"Refusing to run tests against database host {host!r}: it looks like a Supabase "
            "(production) database. Point DATABASE_URL at a local Postgres (docker compose up -d, "
            "or export DATABASE_URL=postgresql://...@127.0.0.1:5433/plandit), or set "
            f"{REMOTE_TEST_DB_OVERRIDE}=1 if you really mean it."
        )


def refuse_remote_test_database(database_url: str, environ=os.environ) -> None:
    refuse_remote_test_host(urlparse(database_url).hostname, environ)
