"""The group plans API (mode 3; brief GE-1 to GE-10, architecture "Mode 3", test plan G3a).

Isolation: every request finds the group through the caller's membership, and anyone who isn't a
member gets an empty 404, never a 304 or a 409, which would show that the group exists. Members are
addressed by their GroupMember id; no response carries an email or a profile id (N-11).

Locking (MF-E), so writes never deadlock or fail at commit:
- every write locks the GroupPlan row by its primary key alone, then checks membership (or the
  invite) again with a fresh query. A lock taken through a join with the members table would
  re-check against the member rows it read before waiting, and miss a removal committed meanwhile;
- create and join insert rows that refer to the caller's profile, so they take the profile's
  key-share lock before the group's, the order account deletion takes them in (core.views);
- the steps that write after the lock are module-level functions (`_write_plan`, `_add_member`,
  `_remove_member`, `_replace_token`, `_end_group`), which the race tests hold to force an order;
- each of those transactions sets a short `lock_timeout`, and a request that waits longer gets
  503 "Try again in a moment." instead of holding one of the API's two workers.
"""

import functools
import logging
import re
from contextlib import contextmanager

from django.conf import settings
from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import DatabaseError, IntegrityError, OperationalError, connection, transaction
from django.db.models import Count, F
from django.utils import timezone
from django.utils.cache import get_conditional_response
from rest_framework import status
from rest_framework.exceptions import AuthenticationFailed, ParseError, PermissionDenied, ValidationError
from rest_framework.response import Response
from rest_framework.views import APIView

from plandit.core.models import Profile
from plandit.core.public_forms import FIRST_NAME_MAX_LENGTH, clean_first_name
from plandit.core.retention import purge_expired

from .models import (
    EDIT_LOG_KEPT,
    INVITE_TOKEN_LENGTH,
    MAX_MEMBERS,
    GroupMember,
    GroupPlan,
    GroupPlanEdit,
    GroupRemoval,
    new_invite_token,
)
from .validation import (
    MAX_REQUEST_BYTES,
    PLAN_MAX_BYTES,
    PlanTooLarge,
    parse_day,
    parse_edit,
    parse_plan,
    parse_uuid,
)

logger = logging.getLogger(__name__)

# How long a group write waits for a row lock before answering 503 (N-13).
LOCK_TIMEOUT = "3s"
# Postgres's SQLSTATE for a lock wait that ran past lock_timeout.
LOCK_NOT_AVAILABLE = "55P03"

SIGN_IN_TO_PLAN_TOGETHER = "Sign in with email or Apple to plan with friends."
TRY_AGAIN = "Try again in a moment."
TOO_LARGE = "This plan is too big to save for the group."
DAY_OVER = "This plan's day is over."
NOT_THIS_PLAN = "This isn't the group's plan."
FALLBACK_NAME = "Friend"
INVITE_TOKEN = re.compile(rf"\A[A-Za-z0-9_-]{{{INVITE_TOKEN_LENGTH}}}\Z")


def invite_url(request, token: str) -> str:
    """plandit.app/j/<token> once the site forwards /j/ here (INVITE_BASE_URL); until then this API's
    own host. Its own setting, like REQUEST_BASE_URL, so /p/ and /g/ links can move on their own."""
    base = getattr(settings, "INVITE_BASE_URL", "") or request.build_absolute_uri("/").rstrip("/")
    return f"{base.rstrip('/')}/j/{token}"


def etag(group: GroupPlan) -> str:
    """Both numbers, so the ETag changes when the plan or the members do (MF-D)."""
    return f'"{group.version}.{group.members_version}"'


def display_name(profile: Profile) -> str:
    """The first word of the profile's name, checked like a friend's first name on the public pages,
    or "Friend" (N-10). It's all other members see of each other."""
    words = (profile.name or "").split()
    if not words:
        return FALLBACK_NAME
    try:
        return clean_first_name(words[0][:FIRST_NAME_MAX_LENGTH])
    except DjangoValidationError:
        return FALLBACK_NAME


def try_again_on_lock_timeout(view_method):
    """503 "Try again in a moment." when a lock wait in the request ran past LOCK_TIMEOUT."""

    @functools.wraps(view_method)
    def wrapper(*args, **kwargs):
        try:
            return view_method(*args, **kwargs)
        except OperationalError as exc:
            cause = exc.__cause__
            if getattr(cause, "sqlstate", None) != LOCK_NOT_AVAILABLE:
                raise
            logger.warning("Group plan write waited past lock_timeout: %s", cause)
            return Response(
                {"detail": TRY_AGAIN}, status=status.HTTP_503_SERVICE_UNAVAILABLE, headers={"Retry-After": "1"}
            )

    return wrapper


@contextmanager
def locking():
    """A transaction whose lock waits end after LOCK_TIMEOUT (set for this transaction only)."""
    with transaction.atomic():
        with connection.cursor() as cursor:
            cursor.execute("SELECT set_config('lock_timeout', %s, true)", [LOCK_TIMEOUT])
        yield


def hold_profile(profile: Profile) -> None:
    """Take the caller's profile's key-share lock before any group lock. A new member row checks its
    profile when the transaction commits, which takes this same lock; taken only then, it would wait
    for an account deletion that holds the profile and is itself waiting for the group this request
    has locked. An account deleted meanwhile is 401, as it would be on the next request."""
    table = connection.ops.quote_name(Profile._meta.db_table)
    column = connection.ops.quote_name(Profile._meta.pk.column)
    with connection.cursor() as cursor:
        cursor.execute(f"SELECT 1 FROM {table} WHERE {column} = %s FOR KEY SHARE", [profile.pk])
        if cursor.fetchone() is None:
            raise AuthenticationFailed("Account deleted.")


def lock_group(pk) -> GroupPlan | None:
    """Row-lock the group by its primary key alone (see the module docstring)."""
    return GroupPlan.objects.select_for_update().filter(pk=pk).first()


def _refuse_anonymous(request) -> None:
    """Old TestFlight builds signed in anonymously; a group shows members by name (N-10)."""
    claims = request.auth if isinstance(request.auth, dict) else {}
    if claims.get("is_anonymous") or request.user.is_anonymous:
        raise PermissionDenied(SIGN_IN_TO_PLAN_TOGETHER)


def _declared_too_large(request) -> Response | None:
    """413 before the body is read, when its declared length is far over the limit."""
    try:
        length = int(request.META.get("CONTENT_LENGTH") or 0)
    except (TypeError, ValueError):
        length = 0
    return _too_large() if length > MAX_REQUEST_BYTES else None


def _too_large() -> Response:
    return Response(
        {"detail": TOO_LARGE, "limitBytes": PLAN_MAX_BYTES}, status=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE
    )


def _body(request) -> dict:
    try:
        body = request.data
    except RecursionError as exc:  # nesting deeper than the parser can follow
        raise ParseError("The request body is nested too deeply.") from exc
    if not isinstance(body, dict):
        raise ValidationError({"detail": "Must be a JSON object."})
    return body


def _with_cache_headers(response, group: GroupPlan, *, tag: str | None = None):
    """Every response that shows a group carries its ETag and may only be cached by the app, which
    must ask again each time (N-6)."""
    response["ETag"] = tag or etag(group)
    response["Cache-Control"] = "private, no-cache"
    return response


def _not_found() -> Response:
    """The same empty 404 for a group that doesn't exist and one the caller isn't in (ISO-2)."""
    return Response(status=status.HTTP_404_NOT_FOUND)


def _members(group: GroupPlan) -> list[GroupMember]:
    return list(group.members.order_by("joined_at", "id"))


def _member_json(group: GroupPlan, member: GroupMember) -> dict:
    return {"id": str(member.id), "name": member.display_name, "isOrganizer": member.profile_id == group.owner_id}


def _detail_json(request, group: GroupPlan, caller: GroupMember, members: list[GroupMember]) -> dict:
    is_organizer = caller.profile_id == group.owner_id
    return {
        "id": str(group.id),
        "date": group.date.isoformat(),
        "version": group.version,
        "membersVersion": group.members_version,
        "plan": group.data,
        "members": [_member_json(group, member) for member in members],
        "memberId": str(caller.id),
        "isOrganizer": is_organizer,
        "inviteUrl": invite_url(request, group.invite_token) if is_organizer else None,
    }


def _detail_response(request, group: GroupPlan, caller: GroupMember, *, status_code=status.HTTP_200_OK):
    body = _detail_json(request, group, caller, _members(group))
    return _with_cache_headers(Response(body, status=status_code), group)


def _purge_quietly() -> None:
    """Expire old group plans and friends' input on an organizer's create (GS-5). Never on a poll
    (N-7), and a failure here never fails the create."""
    try:
        with transaction.atomic():
            purge_expired()
    except DatabaseError:
        logger.exception("purge_expired failed during a group plan create")


def _create_group(owner: Profile, day, plan: dict) -> GroupPlan:
    """Insert the group and its organizer's membership. Runs with the owner's profile held."""
    group = GroupPlan.objects.create(owner=owner, plan_id=parse_uuid(plan["id"]), date=day, data=plan)
    GroupMember.objects.create(group=group, profile=owner, display_name=display_name(owner))
    return group


def _write_plan(group: GroupPlan, caller: GroupMember, plan: dict, edit_id, kind: str, stop_ids: list[str]) -> None:
    """Store an edit made from the current version, with the group locked and the caller's
    membership checked under that lock. The log keeps the latest EDIT_LOG_KEPT edits."""
    group.data = plan
    group.version += 1
    group.save(update_fields=["data", "version", "updated_at"])
    GroupPlanEdit.objects.create(
        group=group, version=group.version, edit_id=edit_id, member_id=caller.id, kind=kind, stop_ids=stop_ids
    )
    if group.version > EDIT_LOG_KEPT:
        GroupPlanEdit.objects.filter(group=group, version__lte=group.version - EDIT_LOG_KEPT).delete()


def _saved_response(group: GroupPlan, version: int):
    """200 for a stored edit: its version, and the members as of now, so the ETag the app keeps
    always matches what it holds."""
    members = _members(group)
    body = {
        "version": version,
        "membersVersion": group.members_version,
        "members": [_member_json(group, member) for member in members],
    }
    return _with_cache_headers(Response(body), group, tag=f'"{version}.{group.members_version}"')


def _conflict_response(group: GroupPlan, base: int):
    """409: the plan as stored, the members, and each logged edit after `base` with its author's
    name as of now (MF-C, N-12): a member who left or deleted their account shows as null."""
    members = _members(group)
    names = {member.id: member.display_name for member in members}
    edits = [
        {
            "version": edit.version,
            "authorId": str(edit.member_id) if edit.member_id in names else None,
            "authorName": names.get(edit.member_id),
            "kind": edit.kind,
            "stopIds": edit.stop_ids,
        }
        for edit in GroupPlanEdit.objects.filter(group=group, version__gt=base).order_by("version")
    ]
    body = {
        "version": group.version,
        "membersVersion": group.members_version,
        "plan": group.data,
        "members": [_member_json(group, member) for member in members],
        "edits": edits,
    }
    return _with_cache_headers(Response(body, status=status.HTTP_409_CONFLICT), group)


def _add_member(group: GroupPlan, profile: Profile) -> GroupMember:
    """Add the caller to the locked group, after the invite was checked again under the lock."""
    member = GroupMember.objects.create(group=group, profile=profile, display_name=display_name(profile))
    group.members_version += 1
    group.save(update_fields=["members_version", "updated_at"])
    return member


def _replace_token(group: GroupPlan) -> None:
    """Turn the old link off (brief GE-8). Members stay; a join that waited for this lock sees the
    new token and is refused (CON-4b)."""
    group.invite_token = new_invite_token()
    group.save(update_fields=["invite_token", "updated_at"])


def _invited_group(token: str) -> GroupPlan | None:
    return GroupPlan.objects.filter(invite_token=token).first() if INVITE_TOKEN.match(token) else None


def _can_use_invite(group: GroupPlan, profile: Profile) -> tuple[bool, GroupMember | None]:
    """Whether the invite works for this caller, and their membership if they have one. It doesn't
    once the plan's day is over (N-7), for someone the organizer removed (MF-G), or for a newcomer
    when the group is full (brief GE-1). The four cases look the same to the caller (N-17)."""
    if group.date < timezone.localdate():
        return False, None
    if GroupRemoval.objects.filter(group=group, profile_id=profile.pk).exists():
        return False, None
    member = GroupMember.objects.filter(group=group, profile=profile).first()
    if member is None and group.members.count() >= MAX_MEMBERS:
        return False, None
    return True, member


class GroupPlanListView(APIView):
    """POST /api/group-plans/: create a group plan from one of the caller's plans (brief GE-1).
    GET: the caller's groups, soonest first, with their ETags."""

    @try_again_on_lock_timeout
    def post(self, request):
        too_large = _declared_too_large(request)
        if too_large is not None:
            return too_large
        _refuse_anonymous(request)
        body = _body(request)
        day = parse_day(body.get("date"))
        try:
            plan = parse_plan(body.get("plan"))
        except PlanTooLarge:
            return _too_large()
        plan_id = parse_uuid(plan["id"])

        _purge_quietly()
        with locking():
            hold_profile(request.user)
            group = GroupPlan.objects.filter(owner=request.user, plan_id=plan_id).first()
            created = group is None
            if created:
                try:
                    with transaction.atomic():
                        group = _create_group(request.user, day, plan)
                except IntegrityError:
                    # A second create of the same plan committed first (a double tap, N-9).
                    group = GroupPlan.objects.get(owner=request.user, plan_id=plan_id)
                    created = False
            caller = GroupMember.objects.get(group=group, profile=request.user)
        return _detail_response(
            request, group, caller, status_code=status.HTTP_201_CREATED if created else status.HTTP_200_OK
        )

    def get(self, request):
        memberships = list(
            GroupMember.objects.filter(profile=request.user)
            .select_related("group")
            .order_by("group__date", "group__created_at", "group__id")
        )
        group_ids = [member.group_id for member in memberships]
        counts = dict(
            GroupMember.objects.filter(group_id__in=group_ids)
            .values("group_id")
            .annotate(count=Count("id"))
            .values_list("group_id", "count")
        )
        organizer_names = dict(
            GroupMember.objects.filter(group_id__in=group_ids, profile_id=F("group__owner_id")).values_list(
                "group_id", "display_name"
            )
        )
        groups = []
        for member in memberships:
            group = member.group
            is_organizer = member.profile_id == group.owner_id
            groups.append(
                {
                    "id": str(group.id),
                    "date": group.date.isoformat(),
                    "version": group.version,
                    "membersVersion": group.members_version,
                    "etag": etag(group),
                    "organizerName": organizer_names.get(group.id, FALLBACK_NAME),
                    "memberCount": counts.get(group.id, 0),
                    "memberId": str(member.id),
                    "isOrganizer": is_organizer,
                    "inviteUrl": invite_url(request, group.invite_token) if is_organizer else None,
                }
            )
        return Response({"groups": groups})


class GroupPlanDetailView(APIView):
    """GET /api/group-plans/<id>/: the plan and its members, with an ETag (brief GE-4).
    `If-None-Match` is compared weakly and a match is 304. A poll never runs the purge (N-7)."""

    def get(self, request, group_id):
        pk = parse_uuid(group_id)
        caller = None
        if pk is not None:
            caller = GroupMember.objects.select_related("group").filter(group_id=pk, profile=request.user).first()
        if caller is None:
            return _not_found()
        group = caller.group
        # After the membership check, so an outsider's conditional GET is 404, never 304.
        not_modified = get_conditional_response(request, etag=etag(group))
        if not_modified is not None:
            return _with_cache_headers(not_modified, group)
        return _detail_response(request, group, caller)

    @try_again_on_lock_timeout
    def put(self, request, group_id):
        """PUT {baseVersion, editId, edit: {kind, stopIds}, plan} (brief GE-5, MF-B, MF-C). A known
        `editId` is 200 with that edit's version and changes nothing; the current `baseVersion`
        stores the plan as the next version; any other is 409 with what changed since."""
        pk = parse_uuid(group_id)
        # Before anything about the body, so an outsider gets the same 404 for any request.
        if pk is None or not GroupMember.objects.filter(group_id=pk, profile=request.user).exists():
            return _not_found()
        too_large = _declared_too_large(request)
        if too_large is not None:
            return too_large
        body = _body(request)
        base, edit_id, kind, stop_ids = parse_edit(body)
        try:
            plan = parse_plan(body.get("plan"))
        except PlanTooLarge:
            return _too_large()

        with locking():
            group = lock_group(pk)
            # Again, under the lock: a removal that committed while this waited counts (CON-3b).
            caller = GroupMember.objects.filter(group=group, profile=request.user).first() if group else None
            if caller is None:
                return _not_found()
            logged = GroupPlanEdit.objects.filter(group=group, edit_id=edit_id).first()
            if logged is not None:
                return _saved_response(group, logged.version)
            if parse_uuid(plan["id"]) != group.plan_id:
                raise ValidationError({"plan": [NOT_THIS_PLAN]})
            if group.date < timezone.localdate():
                return Response({"detail": DAY_OVER}, status=status.HTTP_400_BAD_REQUEST)
            if base != group.version:
                return _conflict_response(group, base)
            _write_plan(group, caller, plan, edit_id, kind, stop_ids)
            return _saved_response(group, group.version)


class GroupInviteView(APIView):
    """GET /api/group-plans/invites/<token>/: what the join sheet shows before joining: the
    organizer's first name, the date and the member count, and nothing else (brief GE-2, INV-2).
    404 when the link doesn't work for the caller. Anonymous sessions may look; they can't join."""

    def get(self, request, token):
        group = _invited_group(token)
        usable = group is not None and _can_use_invite(group, request.user)[0]
        if not usable:
            return _not_found()
        organizer = GroupMember.objects.filter(group=group, profile_id=group.owner_id).first()
        body = {
            "organizerName": organizer.display_name if organizer else FALLBACK_NAME,
            "date": group.date.isoformat(),
            "memberCount": group.members.count(),
        }
        response = Response(body)
        response["Cache-Control"] = "private, no-cache"
        return response


class GroupJoinView(APIView):
    """POST /api/group-plans/invites/<token>/join: join the group (brief GE-2). 200 with the group,
    as GET answers it; joining again, or as the organizer, changes nothing. 404 when the link
    doesn't work for the caller (`_can_use_invite`)."""

    @try_again_on_lock_timeout
    def post(self, request, token):
        _refuse_anonymous(request)
        if _invited_group(token) is None:
            return _not_found()
        with locking():
            hold_profile(request.user)
            pk = GroupPlan.objects.filter(invite_token=token).values_list("pk", flat=True).first()
            group = lock_group(pk) if pk is not None else None
            # Again, under the lock: the link may have been replaced, the group ended or filled, or
            # the caller removed while this waited (CON-2, CON-4b).
            if group is None or group.invite_token != token:
                return _not_found()
            usable, caller = _can_use_invite(group, request.user)
            if not usable:
                return _not_found()
            if caller is None:
                caller = _add_member(group, request.user)
        return _detail_response(request, group, caller)


class GroupInviteReplaceView(APIView):
    """POST /api/group-plans/<id>/invite: the organizer turns the old link off and gets a new one
    (brief GE-8). 200 `{inviteUrl}`. Anyone else gets 404 and the link stays."""

    @try_again_on_lock_timeout
    def post(self, request, group_id):
        pk = parse_uuid(group_id)
        if pk is None:
            return _not_found()
        with locking():
            group = lock_group(pk)
            if group is None or group.owner_id != request.user.pk:
                return _not_found()
            _replace_token(group)
        return Response({"inviteUrl": invite_url(request, group.invite_token)})
