"""Friends' input links (group plans, mode 2): the organizer's API under /api/plan-requests/.

The organizer's app creates a request and sends its /g/ link. It reads friends' answers here,
builds the plan on the phone, and shares it with POST /api/shares/ and this request's slug, which
marks the request built (plandit.shares.views). Only the owner can see or change a request; anyone
else gets 404, so a slug's existence isn't revealed (brief GS-1)."""

import uuid

from django.conf import settings
from django.db import transaction
from django.utils import timezone
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from plandit.core.metrics import iso_utc
from plandit.core.retention import purge_expired

from .models import GroupAnswer, GroupRequest
from .request_serializers import GroupRequestSerializer


def request_url(request, slug: str) -> str:
    """plandit.app/g/<slug> once the site forwards /g/ here (SHARE_BASE_URL); until then this API's own host."""
    base = getattr(settings, "SHARE_BASE_URL", "") or request.build_absolute_uri("/").rstrip("/")
    return f"{base.rstrip('/')}/g/{slug}"


def takes_answers(group: GroupRequest) -> bool:
    """Open, and before its deadline (brief GI-3). The deadline is never after the end of the
    request's range on its day, so a request stops taking answers long before it expires."""
    return group.status == GroupRequest.Status.OPEN and timezone.now() < group.answers_by


def shown_status(group: GroupRequest) -> str:
    """`open` while friends can answer; `built` once its plan was shared; `closed` otherwise, by
    the organizer or by the deadline."""
    if takes_answers(group):
        return GroupRequest.Status.OPEN
    if group.status == GroupRequest.Status.BUILT:
        return GroupRequest.Status.BUILT
    return GroupRequest.Status.CLOSED


class PlanRequestListView(APIView):
    """POST /api/plan-requests/: create a friends' input link (brief GI-1). 201 with the request."""

    def post(self, request):
        serializer = GroupRequestSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data
        group = GroupRequest.objects.create(
            owner=request.user,
            places=[dict(place) for place in data["places"]],
            day=data["day"],
            window_start=data["windowStart"],
            window_end=data["windowEnd"],
            time_zone=data["timeZone"],
            answers_by=data["answersBy"],
        )
        return Response(_request_json(request, group), status=status.HTTP_201_CREATED)


class PlanRequestDetailView(APIView):
    """GET /api/plan-requests/<slug>/: the request with every friend's answer, oldest first (brief
    GI-4). DELETE: the request and its answers are gone, and its link stops working."""

    def get(self, request, slug):
        purge_expired()
        group = GroupRequest.objects.select_related("shared_plan").filter(slug=slug, owner=request.user).first()
        if group is None:
            return Response(status=status.HTTP_404_NOT_FOUND)
        return Response(_request_json(request, group))

    def delete(self, request, slug):
        with transaction.atomic():
            # Lock the request first. A friend's answer is saved with this lock held, so the delete
            # waits for it and takes it along, instead of missing it and failing at commit.
            group = GroupRequest.objects.select_for_update().filter(slug=slug, owner=request.user).first()
            if group is None:
                return Response(status=status.HTTP_404_NOT_FOUND)
            group.delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


class PlanRequestCloseView(APIView):
    """POST /api/plan-requests/<slug>/close/: stop taking answers before the deadline (brief GI-3).
    204, also when it was already closed. A built request stays built."""

    def post(self, request, slug):
        with transaction.atomic():
            group = GroupRequest.objects.select_for_update().filter(slug=slug, owner=request.user).first()
            if group is None:
                return Response(status=status.HTTP_404_NOT_FOUND)
            if group.status == GroupRequest.Status.OPEN:
                group.status = GroupRequest.Status.CLOSED
                group.save(update_fields=["status", "updated_at"])
        return Response(status=status.HTTP_204_NO_CONTENT)


class PlanRequestAnswerDetailView(APIView):
    """DELETE /api/plan-requests/<slug>/answers/<id>/: the organizer removes a friend's answer
    (brief GS-4). Anyone else gets 404. The id may come in either case: the app sends Swift UUIDs,
    which are upper case."""

    def delete(self, request, slug, answer_id):
        try:
            answer_id = uuid.UUID(answer_id)
        except ValueError:
            return Response(status=status.HTTP_404_NOT_FOUND)
        deleted, _ = GroupAnswer.objects.filter(id=answer_id, request__slug=slug, request__owner=request.user).delete()
        return Response(status=status.HTTP_204_NO_CONTENT if deleted else status.HTTP_404_NOT_FOUND)


def _request_json(request, group: GroupRequest) -> dict:
    return {
        "slug": group.slug,
        "url": request_url(request, group.slug),
        "status": shown_status(group),
        "places": group.places,
        "day": group.day.isoformat(),
        "windowStart": _hour_minute(group.window_start),
        "windowEnd": _hour_minute(group.window_end),
        "timeZone": group.time_zone,
        "answersBy": iso_utc(group.answers_by),
        "planSlug": group.shared_plan.slug if group.shared_plan_id else None,
        "createdAt": iso_utc(group.created_at),
        "answers": [_answer_json(answer) for answer in group.answers.order_by("created_at", "id")],
    }


def _answer_json(answer: GroupAnswer) -> dict:
    return {
        "id": str(answer.id),
        "name": answer.name,
        "budget": answer.budget,
        "freeFrom": _hour_minute(answer.free_from),
        "freeUntil": _hour_minute(answer.free_until),
        "stars": answer.stars,
        "createdAt": iso_utc(answer.created_at),
        "updatedAt": iso_utc(answer.updated_at),
    }


def _hour_minute(moment) -> str:
    return moment.strftime("%H:%M")
