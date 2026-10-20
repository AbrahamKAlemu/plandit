"""
Django settings for the Plandit API.

Every secret and environment-specific value comes from environment variables
(or a local .env file, see .env.example). Nothing secret lives in this file.
"""

import os
from pathlib import Path

import dj_database_url
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def env_bool(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def env_list(name: str, default: str = "") -> list[str]:
    return [item.strip() for item in env(name, default).split(",") if item.strip()]


# --- Core -------------------------------------------------------------------

DEBUG = env_bool("DJANGO_DEBUG", False)

SECRET_KEY = env("DJANGO_SECRET_KEY")
if not SECRET_KEY:
    if not DEBUG:
        raise RuntimeError("DJANGO_SECRET_KEY must be set when DJANGO_DEBUG is off.")
    SECRET_KEY = "insecure-dev-only-key"

ALLOWED_HOSTS = env_list("DJANGO_ALLOWED_HOSTS", "localhost,127.0.0.1")
CSRF_TRUSTED_ORIGINS = env_list("DJANGO_CSRF_TRUSTED_ORIGINS")

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "rest_framework",
    "corsheaders",
    "plandit.core",
    "plandit.places",
    "plandit.saved",
    "plandit.plans",
    "plandit.waitlist",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "whitenoise.middleware.WhiteNoiseMiddleware",
    "corsheaders.middleware.CorsMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "config.urls"
WSGI_APPLICATION = "config.wsgi.application"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

# --- Database: Supabase Postgres when deployed, local Postgres in development ---

DATABASES = {
    "default": dj_database_url.config(
        env="DATABASE_URL",
        default="postgresql://plandit:plandit@localhost:5433/plandit",
        conn_max_age=int(env("DATABASE_CONN_MAX_AGE", "600")),
        conn_health_checks=True,
    )
}

if str(DATABASES["default"].get("PORT")) == "6543" or env_bool("DATABASE_TRANSACTION_POOLER"):
    # Supabase's transaction-mode pooler (port 6543) gives every transaction a different
    # server connection, so nothing may be kept on the connection between requests.
    DATABASES["default"]["DISABLE_SERVER_SIDE_CURSORS"] = True
    DATABASES["default"]["CONN_MAX_AGE"] = 0
    DATABASES["default"].setdefault("OPTIONS", {})["prepare_threshold"] = None

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# --- Auth: API callers are Supabase Auth users; Django's own auth is admin-only ---

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

SUPABASE_URL = env("SUPABASE_URL").rstrip("/")
SUPABASE_JWT_SECRET = env("SUPABASE_JWT_SECRET")  # legacy HS256 projects only
SUPABASE_JWKS_URL = env("SUPABASE_JWKS_URL") or (
    f"{SUPABASE_URL}/auth/v1/.well-known/jwks.json" if SUPABASE_URL else ""
)
SUPABASE_JWT_AUDIENCE = "authenticated"
SUPABASE_JWT_ISSUER = f"{SUPABASE_URL}/auth/v1" if SUPABASE_URL else None

REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": ["plandit.core.auth.SupabaseJWTAuthentication"],
    "DEFAULT_PERMISSION_CLASSES": ["rest_framework.permissions.IsAuthenticated"],
    "DEFAULT_RENDERER_CLASSES": ["rest_framework.renderers.JSONRenderer"],
    "DEFAULT_PARSER_CLASSES": ["rest_framework.parsers.JSONParser"],
    "DEFAULT_THROTTLE_RATES": {"anon": "60/min", "user": "600/min", "waitlist": "10/min"},
    "COERCE_DECIMAL_TO_STRING": False,
}
if DEBUG:
    REST_FRAMEWORK["DEFAULT_RENDERER_CLASSES"].append("rest_framework.renderers.BrowsableAPIRenderer")

# --- CORS: only the marketing site calls the API from a browser (the waitlist form) ---

CORS_ALLOWED_ORIGINS = env_list("CORS_ALLOWED_ORIGINS", "https://plandit.app,https://www.plandit.app")
CORS_ALLOW_ALL_ORIGINS = DEBUG
CORS_URLS_REGEX = r"^/api/.*$"

# --- Behind a TLS-terminating proxy in every deployed environment ---

if not DEBUG:
    SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
    SESSION_COOKIE_SECURE = True
    CSRF_COOKIE_SECURE = True

# --- Plandit ----------------------------------------------------------------

# Dotted path to the class that turns post text into a Place. Swap for an LLM + places API later.
PLANDIT_PLACE_MATCHER = env("PLANDIT_PLACE_MATCHER", "plandit.saved.extraction.NameMatcher")
PLANDIT_OEMBED_TIMEOUT_SECONDS = float(env("PLANDIT_OEMBED_TIMEOUT_SECONDS", "5"))

# --- I18N / static ------------------------------------------------------------

LANGUAGE_CODE = "en-us"
TIME_ZONE = "America/New_York"
USE_I18N = True
USE_TZ = True

STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
STORAGES = {
    "default": {"BACKEND": "django.core.files.storage.FileSystemStorage"},
    "staticfiles": {"BACKEND": "whitenoise.storage.CompressedStaticFilesStorage"},
}

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {"plain": {"format": "%(asctime)s %(levelname)s %(name)s: %(message)s"}},
    "handlers": {"console": {"class": "logging.StreamHandler", "formatter": "plain"}},
    "root": {"handlers": ["console"], "level": env("LOG_LEVEL", "INFO")},
    "loggers": {"django.request": {"level": "WARNING"}},
}
