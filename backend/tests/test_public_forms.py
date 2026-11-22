"""The pieces every public form shares (group plans, slice G0): rate limits, the responder cookie,
the client's address and the first-name check (brief GS-2, GS-4)."""

import base64
import hashlib
import threading
import time

import pytest
from django.core.cache import caches
from django.core.exceptions import ValidationError
from django.db import connection, connections
from django.http import HttpResponse
from django.test import RequestFactory

from plandit.core import public_forms
from plandit.core.public_forms import clean_first_name, client_ip, rate_limited, responder_token


@pytest.fixture(autouse=True)
def empty_throttle_cache():
    caches["throttle"].clear()
    yield
    caches["throttle"].clear()


@pytest.fixture
def clock(monkeypatch):
    """Pins time.time(), which the rate limit and the cache's expiry both read, to a settable value
    at the start of an hour."""
    now = {"t": 1_800_000_000.0 - 1_800_000_000.0 % 3600}
    monkeypatch.setattr(time, "time", lambda: now["t"])
    return now


# --- rate_limited -------------------------------------------------------------


def test_allows_up_to_the_limit_then_refuses(clock):
    assert [rate_limited("ip:203.0.113.7", 3, 3600) for _ in range(5)] == [False, False, False, True, True]


def test_the_count_lasts_the_whole_window(clock):
    for _ in range(3):
        rate_limited("ip:203.0.113.7", 3, 3600)
    clock["t"] += 3599
    assert rate_limited("ip:203.0.113.7", 3, 3600)


def test_a_new_window_starts_over(clock):
    for _ in range(3):
        rate_limited("ip:203.0.113.7", 3, 3600)
    clock["t"] += 3600
    assert not rate_limited("ip:203.0.113.7", 3, 3600)


def test_keys_are_counted_separately(clock):
    for _ in range(3):
        rate_limited("ip:203.0.113.7", 3, 3600)
    assert rate_limited("ip:203.0.113.7", 3, 3600)
    assert not rate_limited("ip:203.0.113.8", 3, 3600)
    assert not rate_limited("link:abc123defg", 3, 3600)


def test_a_limit_of_zero_refuses_everything(clock):
    assert rate_limited("ip:203.0.113.7", 0, 3600)


@pytest.mark.django_db(transaction=True)
def test_concurrent_requests_never_pass_the_limit_with_the_database_cache(settings):
    """Production's backend, on the table shares/0002 creates: 8 threads race for 20 slots."""
    settings.CACHES = {
        **settings.CACHES,
        "throttle": {
            "BACKEND": "django.core.cache.backends.db.DatabaseCache",
            "LOCATION": "plandit_throttle_cache",
        },
    }
    allowed = []
    lock = threading.Lock()
    start = threading.Barrier(8)

    def hit_five_times():
        try:
            start.wait()
            for _ in range(5):
                if not rate_limited("ip:203.0.113.7", 20, 3600):
                    with lock:
                        allowed.append(1)
        finally:
            connections.close_all()

    threads = [threading.Thread(target=hit_five_times) for _ in range(8)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    try:
        assert len(allowed) == 20
        # The table keeps a keyed hash of the key, never the address itself.
        with connection.cursor() as cursor:
            cursor.execute("select cache_key from plandit_throttle_cache")
            keys = [row[0] for row in cursor.fetchall()]
        assert len(keys) == 20
        assert not any("203.0.113.7" in key for key in keys)
    finally:
        caches["throttle"].clear()


# --- responder_token ----------------------------------------------------------


def page_request(cookie=None):
    request = RequestFactory().get("/p/abc123defg")
    if cookie is not None:
        request.COOKIES["pa"] = cookie
    return request


def test_a_new_visitor_gets_a_cookie_and_only_its_hash_comes_back():
    response = HttpResponse()
    responder = responder_token(page_request(), response, "/p/abc123defg")

    cookie = response.cookies["pa"]
    token = cookie.value
    assert len(base64.urlsafe_b64decode(token + "=")) == 32
    assert responder == hashlib.sha256(token.encode()).hexdigest()
    assert token not in responder
    assert cookie["path"] == "/p/abc123defg"
    assert cookie["httponly"] is True
    assert cookie["secure"] is True
    assert cookie["samesite"] == "Lax"
    assert cookie["max-age"] == 30 * 24 * 60 * 60


def test_a_returning_visitor_keeps_their_cookie():
    first = HttpResponse()
    responder = responder_token(page_request(), first, "/p/abc123defg")
    token = first.cookies["pa"].value

    again = HttpResponse()
    assert responder_token(page_request(token), again, "/p/abc123defg") == responder
    assert "pa" not in again.cookies


def test_two_visitors_get_different_responders():
    a = responder_token(page_request(), HttpResponse(), "/p/abc123defg")
    b = responder_token(page_request(), HttpResponse(), "/p/abc123defg")
    assert a != b


@pytest.mark.parametrize("cookie", ["", "short", "a" * 42 + "!", "a" * 44])
def test_a_cookie_that_was_not_issued_by_us_is_replaced(cookie):
    response = HttpResponse()
    responder = responder_token(page_request(cookie), response, "/p/abc123defg")
    assert response.cookies["pa"].value != cookie
    assert responder != hashlib.sha256(cookie.encode()).hexdigest()


# --- client_ip ----------------------------------------------------------------


def test_behind_the_proxy_the_address_our_proxy_added_is_the_client(settings):
    settings.BEHIND_TRUSTED_PROXY = True
    settings.TRUSTED_PROXY_HOPS = 1
    request = RequestFactory().get("/", HTTP_X_FORWARDED_FOR="203.0.113.7", REMOTE_ADDR="10.0.0.2")
    assert client_ip(request) == "203.0.113.7"


def test_an_address_the_client_sent_itself_is_ignored(settings):
    """Render's proxy appends the address it saw to whatever X-Forwarded-For the client sent, so a
    client can pick the first entry but not the last."""
    settings.BEHIND_TRUSTED_PROXY = True
    settings.TRUSTED_PROXY_HOPS = 1
    for faked in ("198.51.100.1", "198.51.100.2, 192.0.2.9"):
        request = RequestFactory().get("/", HTTP_X_FORWARDED_FOR=f"{faked}, 203.0.113.7", REMOTE_ADDR="10.0.0.2")
        assert client_ip(request) == "203.0.113.7"


def test_with_two_proxy_hops_the_second_entry_from_the_right_is_the_client(settings):
    settings.BEHIND_TRUSTED_PROXY = True
    settings.TRUSTED_PROXY_HOPS = 2
    request = RequestFactory().get(
        "/", HTTP_X_FORWARDED_FOR="198.51.100.1, 203.0.113.7, 10.0.0.1", REMOTE_ADDR="10.0.0.2"
    )
    assert client_ip(request) == "203.0.113.7"


def test_without_a_trusted_proxy_the_forwarded_header_is_ignored(settings):
    settings.BEHIND_TRUSTED_PROXY = False
    request = RequestFactory().get("/", HTTP_X_FORWARDED_FOR="203.0.113.7", REMOTE_ADDR="198.51.100.4")
    assert client_ip(request) == "198.51.100.4"


@pytest.mark.parametrize(
    ("forwarded", "hops"),
    [(None, 1), ("", 1), ("not-an-address", 1), ("10.0.0.1, ", 1), ("203.0.113.7", 2)],
)
def test_a_missing_garbled_or_short_forwarded_header_falls_back_to_the_peer(settings, forwarded, hops):
    settings.BEHIND_TRUSTED_PROXY = True
    settings.TRUSTED_PROXY_HOPS = hops
    extra = {} if forwarded is None else {"HTTP_X_FORWARDED_FOR": forwarded}
    request = RequestFactory().get("/", REMOTE_ADDR="198.51.100.4", **extra)
    assert client_ip(request) == "198.51.100.4"


def test_ipv6_addresses_count_as_their_64_network(settings):
    """One device usually owns a whole /64, so stepping through it mustn't give fresh limits."""
    settings.BEHIND_TRUSTED_PROXY = True
    settings.TRUSTED_PROXY_HOPS = 1
    for typed in ("2001:DB8:0:0::1", "2001:db8::ffff:1234", "2001:db8:0:0:abcd::9"):
        request = RequestFactory().get("/", HTTP_X_FORWARDED_FOR=typed, REMOTE_ADDR="10.0.0.2")
        assert client_ip(request) == "2001:db8::/64"
    other = RequestFactory().get("/", HTTP_X_FORWARDED_FOR="2001:db8:0:1::1", REMOTE_ADDR="10.0.0.2")
    assert client_ip(other) == "2001:db8:0:1::/64"


def test_an_ipv4_mapped_ipv6_address_counts_as_the_ipv4_address(settings):
    settings.BEHIND_TRUSTED_PROXY = False
    request = RequestFactory().get("/", REMOTE_ADDR="::ffff:203.0.113.7")
    assert client_ip(request) == "203.0.113.7"


def test_the_default_matches_the_reported_render_chain(settings):
    """Client-sent entry, the client, a Cloudflare edge, a Render internal address."""
    settings.BEHIND_TRUSTED_PROXY = True
    settings.TRUSTED_PROXY_HOPS = 3
    request = RequestFactory().get(
        "/", HTTP_X_FORWARDED_FOR="198.51.100.1, 203.0.113.7, 172.71.0.5, 10.0.0.1", REMOTE_ADDR="10.0.0.2"
    )
    assert client_ip(request) == "203.0.113.7"


def test_describe_forwarding_has_the_chain_shape_and_no_addresses():
    request = RequestFactory().get(
        "/",
        HTTP_X_FORWARDED_FOR="198.51.100.1, 203.0.113.7, 172.71.0.5, 10.0.0.1",
        HTTP_TRUE_CLIENT_IP="203.0.113.7",
    )
    described = public_forms.describe_forwarding(request)
    # Python counts the documentation ranges (198.51.100.0/24, 203.0.113.0/24) as private.
    assert described == (
        "forwarded_entries=4 private_from_right=p-pp true_client_ip=present true_client_ip_from_right=3"
    )
    assert "203.0.113" not in described and "10.0.0" not in described


def test_describe_forwarding_without_headers():
    described = public_forms.describe_forwarding(RequestFactory().get("/"))
    assert described == "forwarded_entries=0 private_from_right=- true_client_ip=absent true_client_ip_from_right=none"


# --- clean_first_name ---------------------------------------------------------


@pytest.mark.parametrize(
    ("typed", "cleaned"),
    [
        ("Maya", "Maya"),
        ("  Maya  ", "Maya"),
        ("Mary   Ann", "Mary Ann"),
        ("Mary\tAnn", "Mary Ann"),
        ("Jean-Luc", "Jean-Luc"),
        ("O'Brien", "O'Brien"),
        ("D’Andre", "D’Andre"),  # iPhone keyboards type a curly apostrophe
        ("José", "José"),
        ("José", "José"),  # a decomposed accent is composed
        ("Zoë", "Zoë"),
        ("Ngọc", "Ngọc"),
        ("李华", "李华"),
        ("Ава", "Ава"),
        ("प्रिया", "प्रिया"),  # Devanagari vowel signs are combining marks
        ("J", "J"),
        ("A" * 30, "A" * 30),
    ],
)
def test_names_people_actually_have_are_accepted(typed, cleaned):
    assert clean_first_name(typed) == cleaned


@pytest.mark.parametrize(
    ("typed", "code"),
    [
        (None, "required"),
        ("", "required"),
        ("   ", "required"),
        ("A" * 31, "max_length"),
        ("  " + "A" * 31 + "  ", "max_length"),
        ("Maya2", "invalid"),
        ("Maya!", "invalid"),
        ("Maya.", "invalid"),
        ("<b>Maya</b>", "invalid"),
        ("Maya​", "invalid"),  # zero-width space
        ("Maya 🙂", "invalid"),
        ("Maya\x00", "invalid"),
        ("-", "invalid"),
        ("' -", "invalid"),
        ("Má́́́ya", "invalid"),  # stacked marks ("Zalgo" text)
        ("́Maya", "invalid"),
    ],
)
def test_names_outside_the_rules_are_refused(typed, code):
    with pytest.raises(ValidationError) as error:
        clean_first_name(typed)
    assert error.value.code == code


def test_blocked_words_match_whole_words_in_any_case(monkeypatch):
    monkeypatch.setattr(public_forms, "name_blocklist", lambda: frozenset({"ann"}))
    for name in ["Ann", "ANN", "Mary Ann", "Mary-Ann", "Ann'Marie"]:
        with pytest.raises(ValidationError) as error:
            clean_first_name(name)
        assert error.value.code == "blocked", name
    for name in ["Joanna", "Annie", "Hannah"]:
        assert clean_first_name(name) == name


def test_every_word_on_the_blocklist_is_refused():
    words = public_forms.name_blocklist()
    assert 0 < len(words) <= 100, "keep the list short"
    for word in words:
        assert word == word.casefold() and " " not in word
        for name in [word, word.upper(), word.capitalize(), f"Maya {word}", f"{word}-Maya"]:
            if len(name) > 30:
                continue
            with pytest.raises(ValidationError) as error:
                clean_first_name(name)
            assert error.value.code == "blocked"
