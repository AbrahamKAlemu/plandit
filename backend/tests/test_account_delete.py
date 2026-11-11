import httpx
import pytest

from plandit.core.models import ActivityDay, ActivityEvent, AppSnapshot, DeletedAccount, Profile
from plandit.saved.models import SavedPost

pytestmark = pytest.mark.django_db

SERVICE_KEY = "service-role-key-for-tests"


USER_NOT_FOUND = {"code": 404, "error_code": "user_not_found", "msg": "User not found"}


class FakeDelete:
    """Stands in for httpx.delete. `outcome` is an int status or an exception to raise; `body`
    is the JSON (dict) or raw text the fake response carries."""

    def __init__(self, outcome, body=None):
        self.outcome = outcome
        self.body = body
        self.calls = []

    def __call__(self, url, *, headers, timeout):
        self.calls.append({"url": url, "headers": headers, "timeout": timeout})
        if isinstance(self.outcome, Exception):
            raise self.outcome
        request = httpx.Request("DELETE", url)
        if isinstance(self.body, dict | list):
            return httpx.Response(self.outcome, json=self.body, request=request)
        return httpx.Response(self.outcome, text=self.body or "", request=request)


@pytest.fixture
def service_key(settings):
    settings.SUPABASE_SERVICE_ROLE_KEY = SERVICE_KEY
    return SERVICE_KEY


@pytest.fixture
def fake_delete(monkeypatch):
    def install(outcome, body=None):
        fake = FakeDelete(outcome, body)
        monkeypatch.setattr(httpx, "delete", fake)
        return fake

    return install


@pytest.fixture
def populated(auth_client, user_id):
    """The user has a snapshot, an event, a saved post and an activity day (from the first request)."""
    assert (
        auth_client.put("/api/me/snapshot/", {"data": {"saved": [], "pastPlans": []}}, format="json").status_code == 200
    )
    assert auth_client.post("/api/me/events/", {"name": "link_saved"}, format="json").status_code == 201
    SavedPost.objects.create(owner_id=user_id, url="https://www.tiktok.com/@x/video/1")
    assert AppSnapshot.objects.filter(profile_id=user_id).exists()
    assert ActivityDay.objects.filter(profile_id=user_id).exists()
    return user_id


def assert_all_data_present(user_id):
    assert Profile.objects.filter(id=user_id).exists()
    assert AppSnapshot.objects.filter(profile_id=user_id).exists()
    assert ActivityEvent.objects.filter(profile_id=user_id).exists()
    assert ActivityDay.objects.filter(profile_id=user_id).exists()
    assert SavedPost.objects.filter(owner_id=user_id).exists()


def assert_all_data_gone(user_id):
    assert not Profile.objects.filter(id=user_id).exists()
    assert not AppSnapshot.objects.filter(profile_id=user_id).exists()
    assert not ActivityEvent.objects.filter(profile_id=user_id).exists()
    assert not ActivityDay.objects.filter(profile_id=user_id).exists()
    assert not SavedPost.objects.filter(owner_id=user_id).exists()


def test_delete_calls_supabase_then_removes_everything(auth_client, populated, service_key, fake_delete, settings):
    fake = fake_delete(200)
    response = auth_client.delete("/api/me/")
    assert response.status_code == 204
    assert_all_data_gone(populated)
    assert len(fake.calls) == 1
    call = fake.calls[0]
    assert call["url"] == f"{settings.SUPABASE_URL}/auth/v1/admin/users/{populated}"
    assert call["headers"] == {"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}"}
    assert call["timeout"] == 10.0


@pytest.mark.parametrize(
    "body",
    [
        USER_NOT_FOUND,
        {"error_code": "user_not_found"},
        {"msg": "User not found"},
        {"message": "USER NOT FOUND"},
        {"code": 404, "message": "The user not found in the system"},
    ],
)
def test_supabase_404_for_a_missing_user_counts_as_success(auth_client, populated, service_key, fake_delete, body):
    fake_delete(404, body)
    assert auth_client.delete("/api/me/").status_code == 204
    assert_all_data_gone(populated)
    assert DeletedAccount.objects.filter(id=populated).exists()


@pytest.mark.parametrize(
    "body",
    [
        None,  # empty body
        "<html><body>404 Not Found</body></html>",  # proxy or wrong path
        "not json",
        {"error_code": "route_not_found", "msg": "No such route"},  # some other GoTrue 404
        {"message": "Not Found"},
        ["user_not_found"],  # JSON but not an object
    ],
)
def test_any_other_404_is_502_and_keeps_data(auth_client, populated, service_key, fake_delete, body):
    fake_delete(404, body)
    assert auth_client.delete("/api/me/").status_code == 502
    assert_all_data_present(populated)
    assert not DeletedAccount.objects.filter(id=populated).exists()


def test_supabase_error_is_502_and_keeps_data(auth_client, populated, service_key, fake_delete):
    fake_delete(500)
    response = auth_client.delete("/api/me/")
    assert response.status_code == 502
    assert "detail" in response.json()
    assert_all_data_present(populated)


@pytest.mark.parametrize("status", [401, 403, 422])
def test_other_supabase_failures_are_502(auth_client, populated, service_key, fake_delete, status):
    fake_delete(status)
    assert auth_client.delete("/api/me/").status_code == 502
    assert_all_data_present(populated)


def test_network_error_is_502_and_keeps_data(auth_client, populated, service_key, fake_delete):
    fake_delete(httpx.ConnectTimeout("timed out"))
    assert auth_client.delete("/api/me/").status_code == 502
    assert_all_data_present(populated)


def test_without_service_key_only_local_data_is_deleted(auth_client, populated, settings, fake_delete, caplog):
    settings.SUPABASE_SERVICE_ROLE_KEY = ""
    fake = fake_delete(200)
    with caplog.at_level("WARNING", logger="plandit.core.views"):
        assert auth_client.delete("/api/me/").status_code == 204
    assert fake.calls == []
    assert_all_data_gone(populated)
    assert any("SUPABASE_SERVICE_ROLE_KEY" in record.getMessage() for record in caplog.records)


def test_delete_only_touches_the_caller(auth_client, other_client, populated, service_key, fake_delete):
    fake_delete(200)
    assert other_client.put("/api/me/snapshot/", {"data": {"x": 1}}, format="json").status_code == 200
    assert auth_client.delete("/api/me/").status_code == 204
    assert other_client.get("/api/me/snapshot/").status_code == 200
    assert Profile.objects.count() == 1


def test_delete_requires_auth(api_client):
    assert api_client.delete("/api/me/").status_code == 401


# --- Tombstone: the access token stays valid until it expires ------------------------------


def test_deleted_account_token_is_rejected_and_nothing_comes_back(
    api_client, auth_client, populated, service_key, fake_delete, settings
):
    fake_delete(200)
    settings.METRICS_API_KEY = "k"
    signups_before = api_client.get("/api/metrics/", HTTP_X_METRICS_KEY="k").json()["totals"]["signups"]
    assert signups_before == 1

    assert auth_client.delete("/api/me/").status_code == 204
    assert DeletedAccount.objects.filter(id=populated).exists()

    response = auth_client.get("/api/me/")
    assert response.status_code == 401
    assert response.json()["detail"] == "Account deleted."
    assert auth_client.put("/api/me/snapshot/", {"data": {"saved": []}}, format="json").status_code == 401
    assert auth_client.post("/api/me/events/", {"name": "plan_built"}, format="json").status_code == 401
    assert not Profile.objects.filter(id=populated).exists()
    assert not AppSnapshot.objects.filter(profile_id=populated).exists()
    assert api_client.get("/api/metrics/", HTTP_X_METRICS_KEY="k").json()["totals"]["signups"] == 0


def test_failed_supabase_delete_writes_no_tombstone(auth_client, populated, service_key, fake_delete):
    fake_delete(500)
    assert auth_client.delete("/api/me/").status_code == 502
    assert not DeletedAccount.objects.filter(id=populated).exists()
    assert auth_client.get("/api/me/").status_code == 200


def test_without_service_key_no_tombstone_and_the_token_recreates_the_profile(
    auth_client, populated, settings, fake_delete
):
    # Documented: the Supabase auth user still exists, so that person must be able to come back.
    settings.SUPABASE_SERVICE_ROLE_KEY = ""
    fake_delete(200)
    assert auth_client.delete("/api/me/").status_code == 204
    assert not DeletedAccount.objects.filter(id=populated).exists()
    assert auth_client.get("/api/me/").status_code == 200
    assert Profile.objects.filter(id=populated).exists()
    assert auth_client.get("/api/me/snapshot/").status_code == 404  # fresh, empty account


def test_tombstone_does_not_affect_other_or_existing_profiles(
    auth_client, other_client, populated, service_key, fake_delete
):
    fake_delete(200)
    assert other_client.get("/api/me/").status_code == 200
    assert auth_client.delete("/api/me/").status_code == 204
    assert other_client.get("/api/me/").status_code == 200
    assert other_client.put("/api/me/snapshot/", {"data": {}}, format="json").status_code == 200


def test_tombstone_only_blocks_the_create_branch(auth_client, user_id, populated, django_assert_num_queries):
    # An existing profile with a stale tombstone (should not happen) keeps working: no extra query on the hot path.
    DeletedAccount.objects.create(id=user_id)
    with django_assert_num_queries(1):  # the profile lookup; claims and activity are already in sync
        assert auth_client.get("/api/me/").status_code == 200


# --- PATCH racing DELETE ------------------------------------------------------------------


def test_patch_that_loses_the_race_with_delete_does_not_resurrect_the_profile(auth_client, user_id, monkeypatch):
    """Simulate DELETE committing after PATCH authenticated but before it took the row lock: the
    last step before the lock is validation, so the tombstone + delete land there."""
    from plandit.core import views

    original_is_valid = views.ProfileSerializer.is_valid

    def delete_then_validate(self, *args, **kwargs):
        DeletedAccount.objects.create(id=user_id)
        Profile.objects.filter(pk=user_id).delete()
        return original_is_valid(self, *args, **kwargs)

    assert auth_client.get("/api/me/").status_code == 200
    monkeypatch.setattr(views.ProfileSerializer, "is_valid", delete_then_validate)

    response = auth_client.patch("/api/me/", {"school": "Columbia University"}, format="json")
    assert response.status_code == 401
    assert response.json()["detail"] == "Account deleted."
    assert not Profile.objects.filter(pk=user_id).exists()

    monkeypatch.undo()
    assert auth_client.get("/api/me/").status_code == 401  # the tombstone holds


def test_profile_serializer_update_never_inserts(profile):
    """Belt and braces under the lock: `save(update_fields=...)` raises instead of INSERTing when
    the row is gone, so even without the lock a PATCH could not bring a profile back."""
    from django.db import transaction

    from plandit.core.serializers import ProfileSerializer

    serializer = ProfileSerializer(profile, data={"school": "NYU"}, partial=True)
    assert serializer.is_valid()
    Profile.objects.filter(pk=profile.pk).delete()
    with pytest.raises(Profile.NotUpdated), transaction.atomic():
        serializer.save()
    assert not Profile.objects.filter(pk=profile.pk).exists()


# --- Sign in with Apple token revocation (App Store guideline 5.1.1(v)) -----------------------


APPLE_CODE = "c9f2a1b3d4e5.0.rrtx.apple-authorization-code-for-tests"
REFRESH_TOKEN = "r8e1f0a2c3b4.0.rrtx.apple-refresh-token-for-tests"
ACCESS_TOKEN = "a7d0e9f1b2c3.0.rrtx.apple-access-token-for-tests"
TOKENS = {"access_token": ACCESS_TOKEN, "refresh_token": REFRESH_TOKEN, "token_type": "Bearer", "expires_in": 3600}
TEAM_ID = "9A6H44778K"
KEY_ID = "TESTKEY123"


@pytest.fixture(scope="module")
def apple_key():
    """A throwaway EC P-256 key pair, the kind Apple issues: (private PEM, public PEM)."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    private = ec.generate_private_key(ec.SECP256R1())
    private_pem = private.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode()
    public_pem = (
        private.public_key()
        .public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
        .decode()
    )
    return private_pem, public_pem


@pytest.fixture
def apple_configured(settings, apple_key):
    """Apple settings on; returns the public key that verifies the client secrets the fake saw."""
    settings.APPLE_TEAM_ID = TEAM_ID
    settings.APPLE_CLIENT_ID = "com.plandit.app"
    settings.APPLE_SIGNIN_KEY_ID = KEY_ID
    settings.APPLE_SIGNIN_PRIVATE_KEY = apple_key[0]
    return apple_key[1]


class FakePost:
    """Stands in for httpx.post for Apple's two endpoints. `token` and `revoke` are each an int
    status, an exception (any BaseException) to raise, or a (status, body) pair where body is a
    dict/list (JSON) or raw text. `on_call` runs before every call (to check what the database
    looks like when Apple is called)."""

    def __init__(self, token=(200, TOKENS), revoke=200, on_call=None):
        self.token = token
        self.revoke = revoke
        self.on_call = on_call
        self.calls = []

    def __call__(self, url, *, data, timeout):
        from plandit.core import apple_signin

        if self.on_call:
            self.on_call(url)
        self.calls.append({"url": url, "data": data, "timeout": timeout})
        outcome = {apple_signin.TOKEN_URL: self.token, apple_signin.REVOKE_URL: self.revoke}[url]
        if isinstance(outcome, BaseException):
            raise outcome
        status_code, body = outcome if isinstance(outcome, tuple) else (outcome, None)
        request = httpx.Request("POST", url)
        if isinstance(body, dict | list):
            return httpx.Response(status_code, json=body, request=request)
        return httpx.Response(status_code, text=body or "", request=request)

    @property
    def urls(self):
        return [call["url"] for call in self.calls]


@pytest.fixture
def fake_post(monkeypatch):
    def install(**kwargs):
        fake = FakePost(**kwargs)
        monkeypatch.setattr(httpx, "post", fake)
        return fake

    return install


def delete_with_code(client, code=APPLE_CODE):
    return client.delete("/api/me/", {"apple_authorization_code": code}, format="json")


@pytest.fixture
def after_commit(django_capture_on_commit_callbacks):
    """The view revokes Apple's tokens in `transaction.on_commit`, once the deletion is committed.
    A non-transactional test never commits, so `with after_commit():` runs those callbacks when
    the block ends, as a real commit would."""
    return lambda: django_capture_on_commit_callbacks(execute=True)


def warnings_logged(caplog):
    return [record.getMessage() for record in caplog.records if record.levelname == "WARNING"]


def assert_no_secrets_logged(caplog, fake, private_key):
    text = caplog.text
    for secret in (APPLE_CODE, REFRESH_TOKEN, ACCESS_TOKEN):
        assert secret not in text
    for line in private_key.strip().splitlines()[1:-1]:  # the key body, not the BEGIN/END markers
        assert line not in text
    for call in fake.calls:
        assert call["data"]["client_secret"] not in text
    assert "client_secret" not in text


def test_apple_code_is_exchanged_then_revoked_with_a_correct_client_secret(
    auth_client, populated, service_key, fake_delete, apple_configured, fake_post, caplog, after_commit
):
    import time

    import jwt

    from plandit.core import apple_signin

    fake_delete(200)
    fake = fake_post()
    with caplog.at_level("INFO"), after_commit():
        assert delete_with_code(auth_client).status_code == 204
    assert_all_data_gone(populated)
    assert DeletedAccount.objects.filter(id=populated).exists()

    assert fake.urls == [apple_signin.TOKEN_URL, apple_signin.REVOKE_URL]
    token_call, revoke_call = fake.calls
    for call in (token_call, revoke_call):
        assert call["timeout"] == httpx.Timeout(4.0, connect=2.0)
        assert (call["timeout"].connect, call["timeout"].read, call["timeout"].write) == (2.0, 4.0, 4.0)
    assert token_call["data"] == {
        "client_id": "com.plandit.app",
        "client_secret": token_call["data"]["client_secret"],
        "code": APPLE_CODE,
        "grant_type": "authorization_code",
    }
    assert revoke_call["data"] == {
        "client_id": "com.plandit.app",
        "client_secret": revoke_call["data"]["client_secret"],
        "token": REFRESH_TOKEN,
        "token_type_hint": "refresh_token",
    }

    secret = token_call["data"]["client_secret"]
    header = jwt.get_unverified_header(secret)
    assert header["alg"] == "ES256"
    assert header["kid"] == KEY_ID
    claims = jwt.decode(secret, apple_configured, algorithms=["ES256"], audience="https://appleid.apple.com")
    assert claims["iss"] == TEAM_ID
    assert claims["sub"] == "com.plandit.app"
    assert claims["aud"] == "https://appleid.apple.com"
    assert claims["exp"] - claims["iat"] == 300
    assert abs(claims["iat"] - time.time()) < 30

    assert any("Apple refresh_token revoked" in record.getMessage() for record in caplog.records)
    assert_no_secrets_logged(caplog, fake, apple_configured)


def test_make_client_secret_uses_the_given_time(apple_configured):
    import jwt

    from plandit.core import apple_signin

    secret = apple_signin.make_client_secret(now=1_700_000_000.7)
    claims = jwt.decode(
        secret,
        apple_configured,
        algorithms=["ES256"],
        audience="https://appleid.apple.com",
        options={"verify_exp": False},
    )
    assert (claims["iat"], claims["exp"]) == (1_700_000_000, 1_700_000_300)


@pytest.mark.django_db(transaction=True)
def test_apple_runs_after_supabase_and_after_the_deletion_is_committed(
    auth_client, populated, service_key, apple_configured, fake_post, monkeypatch
):
    """A real commit (no test transaction around the request): by the time Apple's token
    endpoint is called the rows are gone, the tombstone exists and no transaction is open."""
    from django.db import connection

    from plandit.core import apple_signin

    sequence = []
    supabase = FakeDelete(200)

    def tracked_delete(url, **kwargs):
        assert_all_data_present(populated)
        sequence.append("supabase")
        return supabase(url, **kwargs)

    def deletion_committed(url):
        assert not connection.in_atomic_block
        assert_all_data_gone(populated)
        assert DeletedAccount.objects.filter(id=populated).exists()
        sequence.append(url)

    monkeypatch.setattr(httpx, "delete", tracked_delete)
    fake_post(on_call=deletion_committed)
    assert delete_with_code(auth_client).status_code == 204
    assert sequence == ["supabase", apple_signin.TOKEN_URL, apple_signin.REVOKE_URL]
    assert_all_data_gone(populated)


class WorkerKilled(BaseException):
    """What a worker timeout or kill looks like from inside the request: not an Exception."""


@pytest.mark.django_db(transaction=True)
@pytest.mark.parametrize("where", ["token", "revoke"])
def test_the_deletion_stands_when_the_worker_dies_during_the_apple_calls(
    auth_client, populated, service_key, fake_delete, apple_configured, fake_post, where
):
    fake_delete(200)
    fake_post(**{where: WorkerKilled()})
    with pytest.raises(WorkerKilled):
        delete_with_code(auth_client)
    assert_all_data_gone(populated)
    assert DeletedAccount.objects.filter(id=populated).exists()


def test_apple_is_not_called_until_the_deletion_commits(
    auth_client, populated, service_key, fake_delete, apple_configured, fake_post, django_capture_on_commit_callbacks
):
    fake_delete(200)
    fake = fake_post()
    with django_capture_on_commit_callbacks() as callbacks:
        assert delete_with_code(auth_client).status_code == 204
        assert fake.calls == []  # the test's transaction has not committed
    assert len(callbacks) == 1
    assert fake.calls == []


def test_without_a_refresh_token_the_access_token_is_revoked(
    auth_client, populated, service_key, fake_delete, apple_configured, fake_post, caplog, after_commit
):
    fake_delete(200)
    fake = fake_post(token=(200, {"access_token": ACCESS_TOKEN, "token_type": "Bearer", "expires_in": 3600}))
    with caplog.at_level("INFO"), after_commit():
        assert delete_with_code(auth_client).status_code == 204
    assert_all_data_gone(populated)
    assert len(fake.calls) == 2
    revoke = fake.calls[1]["data"]
    assert (revoke["token"], revoke["token_type_hint"]) == (ACCESS_TOKEN, "access_token")
    assert any("Apple access_token revoked" in record.getMessage() for record in caplog.records)
    assert_no_secrets_logged(caplog, fake, apple_configured)


@pytest.mark.parametrize(
    ("token", "revoke", "expected", "calls"),
    [
        ((400, {"error": "invalid_grant"}), 200, "token exchange returned 400", 1),
        (500, 200, "token exchange returned 500", 1),
        (httpx.ConnectTimeout("timed out"), 200, "token exchange request failed", 1),
        (httpx.ReadTimeout("timed out"), 200, "token exchange request failed", 1),
        ((200, {"id_token": "x", "token_type": "Bearer"}), 200, "no refresh or access token", 1),
        ((200, {"access_token": "", "refresh_token": None}), 200, "no refresh or access token", 1),
        ((200, "<html>Service Unavailable</html>"), 200, "non-JSON body", 1),
        ((200, ["not", "an", "object"]), 200, "unexpected body", 1),
        ((200, TOKENS), 400, "revoke returned 400", 2),
        ((200, TOKENS), 503, "revoke returned 503", 2),
        ((200, TOKENS), httpx.ConnectError("refused"), "revoke request failed", 2),
    ],
)
def test_apple_failures_are_logged_and_the_deletion_still_completes(
    auth_client,
    populated,
    service_key,
    fake_delete,
    apple_configured,
    fake_post,
    caplog,
    after_commit,
    token,
    revoke,
    expected,
    calls,
):
    fake_delete(200)
    fake = fake_post(token=token, revoke=revoke)
    with caplog.at_level("WARNING"), after_commit():
        assert delete_with_code(auth_client).status_code == 204
    assert_all_data_gone(populated)
    assert DeletedAccount.objects.filter(id=populated).exists()
    assert len(fake.calls) == calls
    warnings = warnings_logged(caplog)
    assert any("Apple token revocation failed" in message and expected in message for message in warnings)
    assert_no_secrets_logged(caplog, fake, apple_configured)


def test_code_without_apple_settings_is_skipped_with_a_warning(
    auth_client, populated, service_key, fake_delete, fake_post, caplog, settings, after_commit
):
    assert settings.APPLE_SIGNIN_PRIVATE_KEY == ""  # settings_test leaves Apple off
    fake_delete(200)
    fake = fake_post()
    with caplog.at_level("WARNING"), after_commit():
        assert delete_with_code(auth_client).status_code == 204
    assert fake.calls == []
    assert_all_data_gone(populated)
    assert any("APPLE_SIGNIN_* settings are not configured" in record.getMessage() for record in caplog.records)
    assert APPLE_CODE not in caplog.text


@pytest.mark.parametrize(
    "missing", ["APPLE_TEAM_ID", "APPLE_CLIENT_ID", "APPLE_SIGNIN_KEY_ID", "APPLE_SIGNIN_PRIVATE_KEY"]
)
def test_any_missing_apple_setting_skips_the_revocation(
    auth_client, populated, service_key, fake_delete, apple_configured, fake_post, settings, after_commit, missing
):
    setattr(settings, missing, "")
    fake_delete(200)
    fake = fake_post()
    with after_commit():
        assert delete_with_code(auth_client).status_code == 204
    assert fake.calls == []
    assert_all_data_gone(populated)


def test_no_code_means_no_apple_call_and_a_log_line(
    auth_client, populated, service_key, fake_delete, apple_configured, fake_post, caplog, after_commit
):
    fake_delete(200)
    fake = fake_post()
    with caplog.at_level("WARNING"), after_commit():
        assert auth_client.delete("/api/me/").status_code == 204
    assert fake.calls == []
    assert_all_data_gone(populated)
    assert any("No Apple authorization code" in record.getMessage() for record in caplog.records)


@pytest.mark.parametrize(
    "body",
    [
        {"apple_authorization_code": 12345},
        {"apple_authorization_code": None},
        {"apple_authorization_code": ["code"]},
        {"apple_authorization_code": {"code": "x"}},
        {"apple_authorization_code": ""},
        {"apple_authorization_code": "   "},
        {"apple_authorization_code": "c" * 1025},
        {"something_else": APPLE_CODE},
        ["apple_authorization_code"],
        "just a string",
    ],
)
def test_an_unusable_code_counts_as_no_code_not_a_400(
    auth_client, populated, service_key, fake_delete, apple_configured, fake_post, after_commit, body
):
    fake_delete(200)
    fake = fake_post()
    with after_commit():
        assert auth_client.delete("/api/me/", body, format="json").status_code == 204
    assert fake.calls == []
    assert_all_data_gone(populated)


def test_a_malformed_json_body_counts_as_no_code(
    auth_client, populated, service_key, fake_delete, apple_configured, fake_post, after_commit
):
    fake_delete(200)
    fake = fake_post()
    with after_commit():
        response = auth_client.generic("DELETE", "/api/me/", data="{not json", content_type="application/json")
    assert response.status_code == 204
    assert fake.calls == []
    assert_all_data_gone(populated)


def test_a_non_json_content_type_counts_as_no_code(
    auth_client, populated, service_key, fake_delete, apple_configured, fake_post, after_commit
):
    fake_delete(200)
    fake = fake_post()
    with after_commit():
        response = auth_client.generic(
            "DELETE", "/api/me/", data=f"apple_authorization_code={APPLE_CODE}", content_type="text/plain"
        )
    assert response.status_code == 204
    assert fake.calls == []
    assert_all_data_gone(populated)


def test_a_code_of_the_maximum_length_is_sent(
    auth_client, populated, service_key, fake_delete, apple_configured, fake_post, after_commit
):
    fake_delete(200)
    fake = fake_post()
    code = "c" * 1024
    with after_commit():
        assert delete_with_code(auth_client, code).status_code == 204
    assert fake.calls[0]["data"]["code"] == code


def test_supabase_failure_is_502_and_apple_is_not_called(
    auth_client, populated, service_key, fake_delete, apple_configured, fake_post, after_commit
):
    fake_delete(500)
    fake = fake_post()
    with after_commit():
        assert delete_with_code(auth_client).status_code == 502
    assert fake.calls == []
    assert_all_data_present(populated)
    assert not DeletedAccount.objects.filter(id=populated).exists()


def test_supabase_network_error_is_502_and_apple_is_not_called(
    auth_client, populated, service_key, fake_delete, apple_configured, fake_post, after_commit
):
    fake_delete(httpx.ConnectTimeout("timed out"))
    fake = fake_post()
    with after_commit():
        assert delete_with_code(auth_client).status_code == 502
    assert fake.calls == []
    assert_all_data_present(populated)


def test_without_service_key_apple_is_still_revoked_after_the_rows_go(
    auth_client, populated, settings, fake_delete, apple_configured, fake_post, after_commit
):
    from plandit.core import apple_signin

    settings.SUPABASE_SERVICE_ROLE_KEY = ""
    supabase = fake_delete(200)
    fake = fake_post(on_call=lambda url: assert_all_data_gone(populated))
    with after_commit():
        assert delete_with_code(auth_client).status_code == 204
    assert supabase.calls == []
    assert fake.urls == [apple_signin.TOKEN_URL, apple_signin.REVOKE_URL]
    assert fake.calls[1]["data"]["token"] == REFRESH_TOKEN
    assert_all_data_gone(populated)
    assert not DeletedAccount.objects.filter(id=populated).exists()  # unchanged: no tombstone without Supabase


def test_other_users_are_untouched_by_an_apple_delete(
    auth_client, other_client, populated, service_key, fake_delete, apple_configured, fake_post
):
    fake_delete(200)
    fake_post()
    assert other_client.put("/api/me/snapshot/", {"data": {"x": 1}}, format="json").status_code == 200
    assert delete_with_code(auth_client).status_code == 204
    assert other_client.get("/api/me/snapshot/").status_code == 200
    assert Profile.objects.count() == 1


def test_delete_with_a_code_requires_auth(api_client, apple_configured, fake_post):
    fake = fake_post()
    assert delete_with_code(api_client).status_code == 401
    assert fake.calls == []


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        (APPLE_CODE, APPLE_CODE),
        ("  padded  ", "padded"),
        ("c" * 1024, "c" * 1024),
        ("c" * 1025, None),
        ("", None),
        (None, None),
        (42, None),
        (b"bytes", None),
        (["list"], None),
        ("abc\ud800def", None),  # a lone surrogate: valid JSON, but not encodable
        ("abcédef", None),
        ("abc\x07def", None),
        ("abc\ndef", None),
        ("abc def", "abc def"),
    ],
)
def test_usable_code(value, expected):
    from plandit.core import apple_signin

    assert apple_signin.usable_code(value) == expected


def test_private_key_newline_escapes_are_converted(monkeypatch):
    """One-line environment editors (Render's) store the .p8 with literal `\\n`; settings.py
    turns them back into line breaks. Loads settings.py afresh under another name to check."""
    import importlib.util
    from pathlib import Path

    import config

    pasted = "-----BEGIN PRIVATE KEY-----\\nMIGTAgEAMBMGByqGSM49\\nAgEGCCqGSM49AwEH\\n-----END PRIVATE KEY-----\\n"
    monkeypatch.setenv("APPLE_SIGNIN_PRIVATE_KEY", pasted)
    monkeypatch.setenv("APPLE_TEAM_ID", TEAM_ID)
    monkeypatch.delenv("APPLE_CLIENT_ID", raising=False)
    spec = importlib.util.spec_from_file_location(
        "config_settings_under_test", Path(config.__file__).parent / "settings.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert module.APPLE_SIGNIN_PRIVATE_KEY == pasted.replace("\\n", "\n")
    assert module.APPLE_SIGNIN_PRIVATE_KEY.count("\n") == 4
    assert module.APPLE_TEAM_ID == TEAM_ID
    assert module.APPLE_CLIENT_ID == "com.plandit.app"


# --- Anything else going wrong on the Apple side: the deletion still completes ----------------


def rsa_private_pem():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    return key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode()


def assert_only_the_type_is_logged(caplog, exc_type, message_fragments=()):
    warnings = warnings_logged(caplog)
    assert "Apple token revocation failed for " in caplog.text
    assert sum(f"unexpected {exc_type}" in message for message in warnings) == 1
    for fragment in message_fragments:
        assert fragment not in caplog.text
    assert all(record.exc_info is None and record.exc_text is None for record in caplog.records)


@pytest.mark.parametrize(
    ("kind", "exc_type", "message_fragments"),
    [
        ("garbage", "ValueError", ["Unable to load PEM"]),
        ("quoted", "ValueError", ["Unable to load PEM"]),
        ("public", "AttributeError", ["has no attribute"]),
        ("rsa", "InvalidKeyError", ["Expected one of", "RSAPrivateKey"]),
    ],
)
def test_a_bad_private_key_is_logged_by_type_and_the_deletion_completes(
    auth_client,
    populated,
    service_key,
    fake_delete,
    apple_configured,
    apple_key,
    fake_post,
    settings,
    caplog,
    after_commit,
    kind,
    exc_type,
    message_fragments,
):
    key = {
        "garbage": "not a key",
        # A .p8 pasted with its quotes and unconverted `\n` escapes. (Quotes around a valid,
        # multi-line .p8 load fine: cryptography skips text outside the PEM markers.)
        "quoted": '"-----BEGIN PRIVATE KEY-----\\nAAAA\\n-----END PRIVATE KEY-----"',
        "public": apple_key[1],
        "rsa": rsa_private_pem(),
    }[kind]
    settings.APPLE_SIGNIN_PRIVATE_KEY = key
    fake_delete(200)
    fake = fake_post()
    with caplog.at_level("INFO"), after_commit():
        assert delete_with_code(auth_client).status_code == 204
    assert_all_data_gone(populated)
    assert DeletedAccount.objects.filter(id=populated).exists()
    assert fake.calls == []  # the client secret could not be made
    assert_only_the_type_is_logged(caplog, exc_type, message_fragments)
    assert_no_secrets_logged(caplog, fake, key)


@pytest.mark.parametrize(("where", "calls"), [("token", 1), ("revoke", 2)])
def test_any_exception_from_an_apple_call_is_logged_by_type_and_the_deletion_completes(
    auth_client, populated, service_key, fake_delete, apple_configured, fake_post, caplog, after_commit, where, calls
):
    fake_delete(200)
    fake = fake_post(**{where: RuntimeError(f"boom {APPLE_CODE} {REFRESH_TOKEN}")})
    with caplog.at_level("INFO"), after_commit():
        assert delete_with_code(auth_client).status_code == 204
    assert_all_data_gone(populated)
    assert DeletedAccount.objects.filter(id=populated).exists()
    assert len(fake.calls) == calls
    assert_only_the_type_is_logged(caplog, "RuntimeError", ["boom"])
    assert_no_secrets_logged(caplog, fake, apple_configured)


@pytest.mark.parametrize(
    "raw_code",
    [
        "abc\\ud800def",  # a lone surrogate: valid JSON, but httpx cannot form-encode it
        "abc\\u00e9def",
        "abc\\u0007def",
    ],
)
def test_a_code_that_is_not_printable_ascii_counts_as_no_code(
    auth_client, populated, service_key, fake_delete, apple_configured, fake_post, caplog, after_commit, raw_code
):
    fake_delete(200)
    fake = fake_post()
    body = f'{{"apple_authorization_code": "{raw_code}"}}'
    with caplog.at_level("WARNING"), after_commit():
        response = auth_client.generic("DELETE", "/api/me/", data=body, content_type="application/json")
    assert response.status_code == 204
    assert fake.calls == []
    assert_all_data_gone(populated)
    assert DeletedAccount.objects.filter(id=populated).exists()
    assert any("No Apple authorization code" in message for message in warnings_logged(caplog))


@pytest.mark.django_db(transaction=True)
def test_an_exception_from_apple_after_a_real_commit_still_answers_204(
    auth_client, populated, service_key, fake_delete, apple_configured, apple_key, fake_post, caplog
):
    """A real commit (no test transaction): the on_commit revocation runs inside the request, so
    an exception there must be caught before the 204 goes out, and its message never logged."""
    fake_delete(200)
    fake = fake_post(token=RuntimeError(f"boom {APPLE_CODE} {REFRESH_TOKEN}"))
    with caplog.at_level("INFO"):
        assert delete_with_code(auth_client).status_code == 204
    assert_all_data_gone(populated)
    assert DeletedAccount.objects.filter(id=populated).exists()
    assert len(fake.calls) == 1
    warnings = warnings_logged(caplog)
    assert len(warnings) == 1 and "unexpected RuntimeError" in warnings[0]
    assert_only_the_type_is_logged(caplog, "RuntimeError", ["boom"])
    assert_no_secrets_logged(caplog, fake, apple_key[0])
