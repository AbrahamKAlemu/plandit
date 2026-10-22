"""Settings used by pytest. Keeps secrets out of the environment and auth deterministic."""

import os

os.environ.setdefault("DJANGO_SECRET_KEY", "test-only-secret-key")
os.environ.setdefault("DJANGO_DEBUG", "0")

from .settings import *  # noqa: E402, F403

SUPABASE_URL = "https://test-project.supabase.co"
SUPABASE_JWT_SECRET = "test-only-jwt-secret-at-least-32-bytes-long"
SUPABASE_JWKS_URL = f"{SUPABASE_URL}/auth/v1/.well-known/jwks.json"
SUPABASE_JWT_ISSUER = f"{SUPABASE_URL}/auth/v1"
REST_FRAMEWORK = {**REST_FRAMEWORK, "DEFAULT_THROTTLE_RATES": {"anon": None, "user": None, "waitlist": "3/min"}}  # noqa: F405
CACHES = {"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
PASSWORD_HASHERS = ["django.contrib.auth.hashers.MD5PasswordHasher"]
