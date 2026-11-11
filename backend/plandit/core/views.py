import hmac
import json
import logging
from decimal import Decimal

from django.conf import settings
from django.db import connection, transaction
from django.utils import timezone
from rest_framework import permissions, status
from rest_framework.exceptions import (
    AuthenticationFailed,
    NotFound,
    ParseError,
    PermissionDenied,
    UnsupportedMediaType,
    ValidationError,
)
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle
from rest_framework.views import APIView

from . import apple_signin, supabase_admin
from .metrics import DEFAULT_DAYS, MAX_DAYS, MIN_DAYS, compute_metrics, iso_utc
from .models import ActivityEvent, ActivityEventName, AppSnapshot, DeletedAccount, Profile
from .serializers import ActivityEventSerializer, ProfileSerializer
from .stats import compute_stats

logger = logging.getLogger(__name__)

SNAPSHOT_MAX_BYTES = 1_000_000
# Refuse to even parse a request body this large; the exact check happens after parsing.
SNAPSHOT_MAX_REQUEST_BYTES = 1_200_000

# iOS `UserProfile` key -> Profile column, mirrored on every snapshot PUT.
PROFILE_TEXT_FIELDS = {
    "name": "name",
    "school": "school",
    "homeBase": "home_base",
    "travelModes": "travel_modes",
}
BUDGET_MIN = Decimal(0)
BUDGET_MAX = Decimal(10000)


class HealthView(APIView):
    authentication_classes: list = []
    permission_classes = [permissions.AllowAny]

    def get(self, request):
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
        return Response({"status": "ok"})


class MeView(APIView):
    def get(self, request):
        return Response(ProfileSerializer(request.user).data)

    def patch(self, request):
        serializer = ProfileSerializer(request.user, data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        with transaction.atomic():
            # Serialize with DELETE: a PATCH that loses the race must not write (and so re-create)
            # a profile that was just deleted.
            serializer.instance = self._lock(request.user.pk)
            serializer.save()
        return Response(serializer.data, status=status.HTTP_200_OK)

    def delete(self, request):
        """Delete the account: the Supabase auth user first (so a failure leaves everything in
        place and the app can retry), then the Profile, which cascades to all of its data, and
        only once that deletion is committed, the person's Sign in with Apple tokens (best effort).

        When Supabase confirmed the deletion a DeletedAccount tombstone is written in the same
        transaction, so the access token (valid until it expires) cannot re-create the profile.
        Without a service key the auth user still exists, so no tombstone: that person can sign
        in again and gets a fresh, empty account.

        The optional JSON body `{"apple_authorization_code": "..."}` comes from an Apple account:
        the app asks Apple for a fresh code right before deleting. App Store guideline 5.1.1(v)
        wants those tokens revoked. Apple goes last because nothing can retry it: once Supabase
        has deleted the auth user the app has no session, so a crash, hang or killed worker during
        the Apple calls must not leave the person's data behind. A revocation failure is logged
        and the deletion stands; the person can also remove Plandit under their Apple ID."""
        profile = request.user
        apple_code = apple_signin.usable_code(self._body_field(request, "apple_authorization_code"))
        if not supabase_admin.is_configured():
            logger.warning("SUPABASE_SERVICE_ROLE_KEY is not configured; deleting only Plandit data for %s", profile.id)
            with transaction.atomic():
                self._lock(profile.pk).delete()
                self._revoke_apple_tokens_after_commit(profile.id, apple_code)
            return Response(status=status.HTTP_204_NO_CONTENT)
        try:
            supabase_admin.delete_auth_user(profile.id)
        except supabase_admin.SupabaseAdminError as exc:
            logger.warning("Account delete for %s stopped: %s", profile.id, exc)
            return Response(
                {"detail": "Could not delete the sign-in account. Try again in a moment."},
                status=status.HTTP_502_BAD_GATEWAY,
            )
        with transaction.atomic():
            # Same row lock as PATCH, so a concurrent PATCH either finishes first or sees no row.
            locked = self._lock(profile.pk)
            DeletedAccount.objects.get_or_create(id=profile.pk)
            locked.delete()
            self._revoke_apple_tokens_after_commit(profile.id, apple_code)
        return Response(status=status.HTTP_204_NO_CONTENT)

    @staticmethod
    def _lock(pk) -> Profile:
        """Row-lock the profile for the current transaction; a profile deleted meanwhile is 401."""
        locked = Profile.objects.select_for_update().filter(pk=pk).first()
        if locked is None:
            raise AuthenticationFailed("Account deleted.")
        return locked

    @staticmethod
    def _body_field(request, name: str):
        """One field of an optional JSON object body. Old app builds send no body; a body that is
        not JSON, not an object or not a JSON content type counts as no value, because the
        deletion must still go ahead."""
        try:
            body = request.data
        except (ParseError, UnsupportedMediaType):
            return None
        return body.get(name) if isinstance(body, dict) else None

    @classmethod
    def _revoke_apple_tokens_after_commit(cls, profile_id, code: str | None) -> None:
        """Called inside the deletion's transaction: Apple is contacted only after the deletion
        is durably committed (straight away in production, which has no outer transaction; when
        an outer transaction commits otherwise), and not at all if it rolls back."""
        transaction.on_commit(lambda: cls._revoke_apple_tokens(profile_id, code))

    @staticmethod
    def _revoke_apple_tokens(profile_id, code: str | None) -> None:
        """Best effort, after the deletion committed. Logs the outcome only and never raises."""
        if code is None:
            logger.warning("No Apple authorization code for %s; Apple tokens not revoked", profile_id)
            return
        if not apple_signin.is_configured():
            logger.warning("APPLE_SIGNIN_* settings are not configured; Apple tokens not revoked for %s", profile_id)
            return
        try:
            revoked = apple_signin.revoke_authorization_code(code)
        except apple_signin.AppleSignInError as exc:
            logger.warning("Apple token revocation failed for %s: %s", profile_id, exc)
            return
        except Exception as exc:
            # A bad private key, a JWT or encoding error, a bug: only the type is logged, because
            # the message (and a traceback's locals) can echo the key, the code or a token.
            logger.warning("Apple token revocation failed for %s: unexpected %s", profile_id, type(exc).__name__)
            return
        logger.info("Apple %s revoked for %s", revoked, profile_id)


class StatsView(APIView):
    def get(self, request):
        return Response(compute_stats(request.user))


def _activate(profile: Profile, now) -> None:
    """Set `activated_at` once: the account did Plandit's core action (built a plan)."""
    if profile.activated_at is None:
        Profile.objects.filter(pk=profile.pk, activated_at__isnull=True).update(activated_at=now)
        profile.activated_at = now


def _mirror_profile(profile: Profile, data: dict, now) -> None:
    """Best effort copy of `data.profile` into the Profile row. Bad values are skipped."""
    raw = data.get("profile")
    if not isinstance(raw, dict):
        return
    updates = {}
    for key, field in PROFILE_TEXT_FIELDS.items():
        value = raw.get(key)
        if isinstance(value, str):
            updates[field] = value[: Profile._meta.get_field(field).max_length]
    budget = raw.get("defaultBudget")
    if isinstance(budget, int | float) and not isinstance(budget, bool):
        try:
            budget = Decimal(str(budget)).quantize(Decimal("0.01"))
        except ArithmeticError:
            budget = None
        if budget is not None and BUDGET_MIN <= budget <= BUDGET_MAX:
            updates["default_budget"] = budget
    if not updates:
        return
    updates["updated_at"] = now
    Profile.objects.filter(pk=profile.pk).update(**updates)
    for field, value in updates.items():
        setattr(profile, field, value)


def _count(value) -> int:
    return len(value) if isinstance(value, list) else 0


def _is_positive_int(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def _has_built_plan(data: dict, today_stop_count: int) -> bool:
    """The core action: a plan with at least one stop, today or in the past. iOS past plans
    carry `stopCount`, not the stops themselves."""
    if today_stop_count > 0:
        return True
    past_plans = data.get("pastPlans")
    if not isinstance(past_plans, list):
        return False
    return any(isinstance(plan, dict) and _is_positive_int(plan.get("stopCount")) for plan in past_plans)


def _too_large(size: int) -> Response:
    return Response(
        {"detail": f"Snapshot is {size} bytes; the limit is {SNAPSHOT_MAX_BYTES}."},
        status=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
    )


class SnapshotView(APIView):
    """The app's whole local store, stored per account and returned byte-for-byte as JSON."""

    def get(self, request):
        snapshot = AppSnapshot.objects.filter(profile=request.user).first()
        if snapshot is None:
            raise NotFound("No snapshot yet.")
        return Response(
            {"version": snapshot.version, "updated_at": iso_utc(snapshot.updated_at), "data": snapshot.data}
        )

    def put(self, request):
        try:
            content_length = int(request.META.get("CONTENT_LENGTH") or 0)
        except (TypeError, ValueError):
            content_length = 0
        if content_length > SNAPSHOT_MAX_REQUEST_BYTES:
            return _too_large(content_length)  # before request.data parses the whole body

        body = request.data
        if not isinstance(body, dict) or not isinstance(body.get("data"), dict):
            raise ValidationError({"data": ["Must be a JSON object."]})
        data = body["data"]
        try:
            size = len(json.dumps(data, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))
        except (TypeError, ValueError) as exc:
            raise ParseError("Snapshot is not valid JSON.") from exc
        if size > SNAPSHOT_MAX_BYTES:
            return _too_large(size)

        profile = request.user
        now = timezone.now()
        today = data.get("today")
        counters = {
            "saved_count": _count(data.get("saved")),
            "past_plans_count": _count(data.get("pastPlans")),
            "today_stop_count": _count(today.get("stops")) if isinstance(today, dict) else 0,
        }
        with transaction.atomic():
            snapshot, _ = AppSnapshot.objects.select_for_update().get_or_create(profile=profile)
            snapshot.data = data
            snapshot.version += 1
            snapshot.updated_at = now
            for field, value in counters.items():
                setattr(snapshot, field, value)
            snapshot.save(update_fields=["data", "version", "updated_at", *counters])
            _mirror_profile(profile, data, now)
            if _has_built_plan(data, counters["today_stop_count"]):
                _activate(profile, now)
        return Response({"version": snapshot.version, "updated_at": iso_utc(snapshot.updated_at)})


class EventsView(APIView):
    """POST /api/me/events/ {"name": "plan_built", "occurred_at": "..."}; 120/min per user."""

    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "events"

    def post(self, request):
        serializer = ActivityEventSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        name = serializer.validated_data["name"]
        occurred_at = serializer.validated_data["occurred_at"]
        with transaction.atomic():
            ActivityEvent.objects.create(profile=request.user, name=name, occurred_at=occurred_at)
            if name == ActivityEventName.PLAN_BUILT:
                _activate(request.user, timezone.now())
        return Response({"name": name, "occurred_at": iso_utc(occurred_at)}, status=status.HTTP_201_CREATED)


class MetricsView(APIView):
    """GET /api/metrics/?days=30 for the course staff. Secret key instead of a JWT; counts only."""

    authentication_classes: list = []
    permission_classes = [permissions.AllowAny]
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "metrics"

    def get(self, request):
        expected = settings.METRICS_API_KEY
        if not expected:
            raise NotFound()
        provided = request.headers.get("X-Metrics-Key") or request.query_params.get("key") or ""
        if not hmac.compare_digest(provided.encode("utf-8"), expected.encode("utf-8")):
            raise PermissionDenied("Invalid metrics key.")
        raw_days = request.query_params.get("days", str(DEFAULT_DAYS))
        try:
            days = int(raw_days)
        except ValueError as exc:
            raise ValidationError({"days": [f"Must be an integer from {MIN_DAYS} to {MAX_DAYS}."]}) from exc
        if not MIN_DAYS <= days <= MAX_DAYS:
            raise ValidationError({"days": [f"Must be an integer from {MIN_DAYS} to {MAX_DAYS}."]})
        return Response(compute_metrics(days))
