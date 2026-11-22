"""What every public form shares: the pages friends answer without an account (/p/, and later /g/).

- `rate_limited` counts requests per key (an IP address, a link) in the `throttle` cache.
- `responder_token` recognizes the same browser again through a cookie, storing only a hash.
- `client_ip` is the address to rate limit by.
- `clean_first_name` is the only free text a friend can type (brief GS-4).
- `public_page_csp` is the Content Security Policy for the pages themselves (brief GS-3).
"""

import hashlib
import ipaddress
import math
import re
import secrets
import time
import unicodedata
from functools import cache
from pathlib import Path

from django.conf import settings
from django.core.cache import caches
from django.core.exceptions import ValidationError
from django.utils.crypto import salted_hmac
from django.utils.csp import CSP
from django.views.decorators.csp import csp_override

# --- Rate limits ------------------------------------------------------------------------------


def rate_limited(key: str, limit: int, window_seconds: int) -> bool:
    """Count one request against `key` and say whether it's over `limit` for the current window.

    Fixed windows aligned to the clock (every hour on the hour for 3600): a client can get up to
    twice the limit through around a window boundary. Refused requests aren't counted.

    Each allowed request claims its own numbered slot in the cache with `add`, which only one
    caller can win: DatabaseCache inserts on the table's primary key and LocMemCache holds a lock.
    So simultaneous requests can't share a count the way a read-then-write counter would, and at
    most `limit` get through per window. (Django's `incr` isn't used: on DatabaseCache it reads,
    then writes, and resets the expiry to the cache's 5-minute default.) A slot costs one table
    row until the window ends, so this suits limits in the tens, not thousands.

    If the cache's database can't be written, every slot looks taken and the request is refused.

    `key` is stored only as a keyed hash, so the table never holds an IP address.
    """
    if window_seconds <= 0:
        raise ValueError("window_seconds must be positive")
    throttle = caches["throttle"]
    now = time.time()
    window = int(now // window_seconds)
    seconds_left = max(1, math.ceil((window + 1) * window_seconds - now))
    digest = salted_hmac("plandit.core.public_forms.rate_limited", key, algorithm="sha256").hexdigest()
    slots = [f"rl:{digest}:{window_seconds}:{window}:{n}" for n in range(limit)]
    taken = throttle.get_many(slots) if slots else {}
    for slot in slots:
        if slot not in taken and throttle.add(slot, 1, timeout=seconds_left):
            return False
    return True


# --- The responder cookie ---------------------------------------------------------------------

RESPONDER_COOKIE = "pa"
RESPONDER_COOKIE_MAX_AGE = 30 * 24 * 60 * 60
_TOKEN_BYTES = 32
_TOKEN_PATTERN = re.compile(r"[A-Za-z0-9_-]{43}")  # secrets.token_urlsafe(32)


def responder_token(request, response, scope: str) -> str:
    """Who is answering, as far as this browser goes: the SHA-256 hex of a random token kept in the
    `pa` cookie. Only the hash is ever stored; the token itself never leaves the cookie.

    `scope` is the cookie's path, such as "/p/<slug>", so each link gets its own token and the
    cookie isn't sent anywhere else. A browser without a valid cookie gets a new token, set on
    `response` (HttpOnly, Secure, SameSite=Lax, 30 days).
    """
    token = request.COOKIES.get(RESPONDER_COOKIE, "")
    if not _TOKEN_PATTERN.fullmatch(token):
        token = secrets.token_urlsafe(_TOKEN_BYTES)
        response.set_cookie(
            RESPONDER_COOKIE,
            token,
            max_age=RESPONDER_COOKIE_MAX_AGE,
            path=scope,
            secure=True,
            httponly=True,
            samesite="Lax",
        )
    return hashlib.sha256(token.encode()).hexdigest()


# --- The client's address ---------------------------------------------------------------------


def client_ip(request) -> str:
    """The address to rate limit by. Behind the deployed proxy (settings.BEHIND_TRUSTED_PROXY), the
    X-Forwarded-For entry our own proxies added: settings.TRUSTED_PROXY_HOPS from the right. Entries
    to the left of it came from the client and can be anything, so the first entry is never used.
    Otherwise, or when that entry is missing or isn't an address, the connecting peer (REMOTE_ADDR).
    Addresses come back normalized, so one IPv6 address has one spelling."""
    if getattr(settings, "BEHIND_TRUSTED_PROXY", False):
        hops = max(1, int(getattr(settings, "TRUSTED_PROXY_HOPS", 1)))
        entries = [entry.strip() for entry in request.META.get("HTTP_X_FORWARDED_FOR", "").split(",")]
        if len(entries) >= hops and (address := _normalized(entries[-hops])):
            return address
    remote = request.META.get("REMOTE_ADDR", "")
    return _normalized(remote) or remote


def _normalized(value: str) -> str:
    try:
        return str(ipaddress.ip_address(value))
    except ValueError:
        return ""


# --- First names ------------------------------------------------------------------------------

FIRST_NAME_MAX_LENGTH = 30
_APOSTROPHES = "'’"  # iPhone keyboards type the curly one
_WORD_SEPARATORS = re.compile(r"[ \-'’]+")
_MAX_MARKS_IN_A_ROW = 2


@cache
def name_blocklist() -> frozenset[str]:
    """plandit/core/data/name_blocklist.txt: one word per line, `#` starts a comment."""
    path = Path(__file__).parent / "data" / "name_blocklist.txt"
    words = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        word = line.split("#", 1)[0].strip()
        if word:
            words.add(unicodedata.normalize("NFKC", word).casefold())
    return frozenset(words)


def clean_first_name(value) -> str:
    """A friend's first name as it will be shown: 1 to 30 characters of letters (any script),
    spaces, hyphens and apostrophes, with spaces trimmed and runs of them collapsed. Raises
    ValidationError with code `required`, `max_length`, `invalid` or `blocked`.

    Letters include the combining marks some scripts write letters with (Devanagari vowel signs,
    Thai tone marks), at most two in a row after a letter, which keeps out stacked-mark text.
    A word on the blocklist is refused as a whole word in any case ("Ann" would block "Mary-Ann"
    but not "Joanna").
    """
    if not isinstance(value, str):
        raise ValidationError("Enter your first name.", code="required")
    name = " ".join(unicodedata.normalize("NFC", value).split())
    if not name:
        raise ValidationError("Enter your first name.", code="required")
    if len(name) > FIRST_NAME_MAX_LENGTH:
        raise ValidationError("Use 30 characters or fewer.", code="max_length")
    if not _letters_spaces_hyphens_apostrophes(name):
        raise ValidationError("Use letters, spaces, hyphens and apostrophes only.", code="invalid")
    blocked = name_blocklist()
    words = _WORD_SEPARATORS.split(unicodedata.normalize("NFKC", name).casefold())
    if any(word in blocked for word in words):
        raise ValidationError("Please use a different name.", code="blocked")
    return name


def _letters_spaces_hyphens_apostrophes(name: str) -> bool:
    has_letter = False
    marks_in_a_row = 0
    previous_is_letter_or_mark = False
    for char in name:
        if char.isalpha():
            has_letter = True
            marks_in_a_row = 0
            previous_is_letter_or_mark = True
        elif unicodedata.category(char) in ("Mn", "Mc"):
            marks_in_a_row += 1
            if not previous_is_letter_or_mark or marks_in_a_row > _MAX_MARKS_IN_A_ROW:
                return False
        elif char == " " or char == "-" or char in _APOSTROPHES:
            marks_in_a_row = 0
            previous_is_letter_or_mark = False
        else:
            return False
    return has_letter


# --- Content Security Policy for the public pages ---------------------------------------------

# No scripts at all. Styles only from the app's static files and Google Fonts' stylesheet; fonts
# from Google Fonts. Images from the app, data: URIs and the website, where the logo and favicons
# live: plandit.app redirects them to www.plandit.app, and the policy checks the redirect too.
# Forms post back to the same site, nobody can frame the page, and there's no <base>.
PUBLIC_PAGE_CSP = {
    "default-src": [CSP.NONE],
    "style-src": [CSP.SELF, "https://fonts.googleapis.com"],
    "font-src": ["https://fonts.gstatic.com"],
    "img-src": [CSP.SELF, "data:", "https://plandit.app", "https://www.plandit.app"],
    "form-action": [CSP.SELF],
    "frame-ancestors": [CSP.NONE],
    "base-uri": [CSP.NONE],
}

# Decorate each public page view (/p/ now, /g/ and /j/ later). Needs Django's
# ContentSecurityPolicyMiddleware, which adds nothing to other responses (SECURE_CSP is empty).
public_page_csp = csp_override(PUBLIC_PAGE_CSP)
