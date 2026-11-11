"""Settings used by pytest. Keeps secrets out of the environment and auth deterministic."""

import os
from pathlib import Path
from urllib.parse import quote

from dotenv import load_dotenv

from .test_db_guard import refuse_remote_test_database

BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")

os.environ.setdefault("DJANGO_SECRET_KEY", "test-only-secret-key")
os.environ.setdefault("DJANGO_DEBUG", "0")
if not os.environ.get("DATABASE_URL"):
    password = os.environ.get("POSTGRES_PASSWORD", "test-only-postgres-password")
    os.environ["DATABASE_URL"] = f"postgresql://plandit:{quote(password, safe='')}@127.0.0.1:5433/plandit"

# Never create a test database on Supabase (production). tests/conftest.py repeats the check so
# it also holds when DJANGO_SETTINGS_MODULE is overridden.
refuse_remote_test_database(os.environ["DATABASE_URL"])

from .settings import *  # noqa: E402, F403

SUPABASE_URL = "https://test-project.supabase.co"
SUPABASE_JWT_SECRET = "test-only-jwt-secret-at-least-32-bytes-long"
SUPABASE_JWKS_URL = f"{SUPABASE_URL}/auth/v1/.well-known/jwks.json"
SUPABASE_JWT_ISSUER = f"{SUPABASE_URL}/auth/v1"
REST_FRAMEWORK = {  # noqa: F405
    **REST_FRAMEWORK,  # noqa: F405
    "DEFAULT_THROTTLE_RATES": {"anon": None, "user": None, "waitlist": "3/min", "events": None, "metrics": None},
}
SUPABASE_SERVICE_ROLE_KEY = ""  # tests that exercise the Admin API set it with the `settings` fixture
APPLE_TEAM_ID = ""  # same: tests that exercise Apple token revocation set these with the `settings` fixture
APPLE_CLIENT_ID = "com.plandit.app"
APPLE_SIGNIN_KEY_ID = ""
APPLE_SIGNIN_PRIVATE_KEY = ""
METRICS_API_KEY = ""  # same: /api/metrics/ is off unless a test turns it on
CACHES = {"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
PASSWORD_HASHERS = ["django.contrib.auth.hashers.MD5PasswordHasher"]
