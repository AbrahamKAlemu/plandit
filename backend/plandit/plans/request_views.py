"""Friends' input links (group plans, mode 2): the organizer's API under /api/plan-requests/, and
the public /g/<slug> page friends answer on.

The organizer's app creates a request and sends its /g/ link. It reads friends' answers here,
builds the plan on the phone, and shares it with POST /api/shares/ and this request's slug, which
marks the request built (plandit.shares.views). Only the owner can see or change a request; anyone
else gets 404, so a slug's existence isn't revealed (brief GS-1).

The page has the same protections as a shared plan's answer form (brief GS-2 to GS-4), with the
same helpers: Django's CSRF check, the per-address limit on each link, the per-link cap as a count
of answers in the database, the first-name check, the `pa` cookie and the page policy."""

import re
import uuid
from datetime import time
from zoneinfo import ZoneInfo

from django.conf import settings
from django.core.exceptions import ValidationError
from django.db import transaction
from django.http import HttpResponse, HttpResponseRedirect
from django.shortcuts import render
from django.urls import reverse
from django.utils import timezone
from django.views.decorators.http import require_POST, require_safe
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from plandit.core.metrics import iso_utc
from plandit.core.public_forms import (
    RESPONDER_COOKIE_MAX_AGE,
    clean_first_name,
    client_ip,
    public_page_csp,
    rate_limited,
    responder_token,
)
from plandit.core.retention import purge_expired
from plandit.shares.views import (
    ANSWERS_PER_ADDRESS,
    ANSWERS_PER_ADDRESS_WINDOW,
    ANSWERS_PER_LINK,
    LINK_FULL,
    TRY_LATER,
    not_found_page,
    with_page_headers,
)

from .models import BUDGET_MAX, MAX_STARS, REQUEST_RETENTION_DAYS, GroupAnswer, GroupRequest
from .request_serializers import GroupRequestSerializer

# The budget is a choice of $0 to $150 in $5 steps, with nothing chosen until the friend picks one
# (a slider, as the architecture had it, can't show its value without JavaScript, and wherever it
# started would answer for a friend who didn't move it). The organizer's own budget is never shown
# to friends (brief GI-5).
BUDGET_STEP = 5
BUDGET_CHOICES = range(0, BUDGET_MAX + 1, BUDGET_STEP)

CHOOSE_A_BUDGET = f"Choose a budget from $0 to ${BUDGET_MAX}."
STAR_UP_TO = f"Star up to {MAX_STARS} places."


def request_url(request, slug: str) -> str:
    """plandit.app/g/<slug> once the site forwards /g/ here (REQUEST_BASE_URL); until then this API's
    own host. Not SHARE_BASE_URL: /p/ links may move to the site before it forwards /g/."""
    base = getattr(settings, "REQUEST_BASE_URL", "") or request.build_absolute_uri("/").rstrip("/")
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


# --- The public page ------------------------------------------------------------------------


@public_page_csp
@require_safe
def request_page(request, slug):
    """GET /g/<slug>: the page friends open. No sign-in. While the request takes answers, its
    places and the form (brief GI-2); once its plan is shared, a redirect to that plan's page
    (GI-7), except for a browser whose answer is still on the request, which gets the plan's link
    and "Take back my answer"; otherwise the closed message (GI-3)."""
    group = GroupRequest.objects.select_related("shared_plan").filter(slug=slug).first()
    if group is None:
        return not_found_page(request)
    if group.status == GroupRequest.Status.BUILT and group.shared_plan_id:
        plan_path = reverse("shared-plan", args=[group.shared_plan.slug])
        if _has_own_answer(request, group):
            return _built_page(request, group, plan_path)
        return with_page_headers(HttpResponseRedirect(plan_path), takes_answers=True)
    if not takes_answers(group):
        return _closed_page(request, group)
    purge_expired()
    return _open_page(request, group)


@public_page_csp
@require_POST
def answer_request(request, slug):
    """POST /g/<slug>/answer: a friend's answer, from the page's form. Django's CSRF check runs
    first. Then the address's limit on this link, the first name, the budget, the free window and
    the stars; then, with the request locked, the per-link cap and the save, matched to the browser
    by its cookie, which is renewed to last as long as the answer. 303 back to the page. Closed
    (410), over a limit (429) or with a bad field (400), the page comes back with the reason."""
    group = GroupRequest.objects.filter(slug=slug).first()
    if group is None:
        return not_found_page(request)
    if not takes_answers(group):
        return _closed_page(request, group, status=410)
    if rate_limited(f"request-answer:{slug}:{client_ip(request)}", ANSWERS_PER_ADDRESS, ANSWERS_PER_ADDRESS_WINDOW):
        return _open_page(request, group, form=_typed(request, group), error=TRY_LATER, status=429)
    # After the limit, so a refused request costs as little as possible.
    purge_expired()

    form = _typed(request, group)
    try:
        name = clean_first_name(request.POST.get("name"))
    except ValidationError as error:
        return _open_page(request, group, form=form, error=error.messages[0], invalid="name", status=400)
    budget = _budget(request.POST.get("budget"))
    if budget is None:
        return _open_page(request, group, form=form, error=CHOOSE_A_BUDGET, invalid="budget", status=400)
    window = _free_window(request, group)
    if window is None:
        return _open_page(request, group, form=form, error=_choose_times(group), invalid="window", status=400)
    stars = _stars(request, group)
    if len(stars) > MAX_STARS:
        return _open_page(request, group, form=form, error=STAR_UP_TO, invalid="stars", status=400)

    path = _request_path(slug)
    response = with_page_headers(HttpResponseRedirect(path, status=303), takes_answers=True)
    responder = responder_token(request, response, path, max_age=_cookie_max_age(group), renew=True)
    with transaction.atomic():
        # Lock the request: the organizer's delete takes the same lock first, so an answer saved
        # now is deleted with the rest instead of failing at commit (as for shared plans).
        group = GroupRequest.objects.select_for_update().filter(pk=group.pk).first()
        if group is None:
            return not_found_page(request)
        if not takes_answers(group):
            return _closed_page(request, group, status=410)
        answers = group.answers.all()
        if not answers.filter(responder=responder).exists() and answers.count() >= ANSWERS_PER_LINK:
            return _open_page(request, group, form=form, error=LINK_FULL, status=429)
        GroupAnswer.objects.update_or_create(
            request=group,
            responder=responder,
            defaults={"name": name, "budget": budget, "free_from": window[0], "free_until": window[1], "stars": stars},
        )
    return response


@public_page_csp
@require_POST
def take_back_request_answer(request, slug):
    """POST /g/<slug>/answer/delete: the browser takes back its own answer, on any request that
    exists, even once it stops taking answers: deleting your own answer is always safe. Not rate
    limited: it can only remove what this browser's cookie wrote. 303 back to the page."""
    group = GroupRequest.objects.filter(slug=slug).first()
    if group is None:
        return not_found_page(request)
    purge_expired()
    GroupAnswer.objects.filter(request=group, responder=_existing_responder(request, slug)).delete()
    return with_page_headers(HttpResponseRedirect(_request_path(slug), status=303), takes_answers=True)


def _open_page(request, group, *, form=None, error="", invalid="", status=200):
    """The places with their stars, and the form: this browser's own answer, or what it just sent
    when `form` comes back with an `error`, or else the whole range and no stars. Other friends'
    answers only show as a count (brief GI-8)."""
    own = group.answers.filter(responder=_existing_responder(request, group.slug)).first()
    if form is None and own:
        form = {
            "name": own.name,
            "budget": own.budget,
            "free_from": own.free_from,
            "free_until": own.free_until,
            "stars": set(own.stars),
        }
    elif form is None:
        form = {
            "name": "",
            "budget": None,
            "free_from": group.window_start,
            "free_until": group.window_end,
            "stars": set(),
        }
    places = [
        {
            **place,
            "details": " · ".join(filter(None, [place.get("neighborhood"), place.get("kind")])),
            "starred": place["id"] in form["stars"],
        }
        for place in group.places
    ]
    response = render(
        request,
        "plans/request.html",
        {
            "slug": group.slug,
            "page_url": request_url(request, group.slug),
            "day_text": day_text(group.day),
            "range_text": _range_text(group.window_start, group.window_end),
            "deadline_text": deadline_text(group),
            "places": places,
            "answer_count": group.answers.count(),
            "own": own,
            "own_window": _range_text(own.free_from, own.free_until) if own else "",
            "form": form | {key: _hour_minute(form[key]) for key in ("free_from", "free_until")},
            "window_start": _hour_minute(group.window_start),
            "window_end": _hour_minute(group.window_end),
            "budget_choices": BUDGET_CHOICES,
            "error": error,
            "invalid": invalid,
        },
        status=status,
    )
    return with_page_headers(response, takes_answers=True)


def _closed_page(request, group, *, status=200):
    """The closed message (brief GI-3), with "Take back my answer" for a browser that answered.
    Never cached: it changes when the plan is shared, and it may carry a form."""
    response = render(
        request,
        "plans/request_closed.html",
        {"slug": group.slug, "page_url": request_url(request, group.slug), "own": _has_own_answer(request, group)},
        status=status,
    )
    return with_page_headers(response, takes_answers=True)


def _built_page(request, group, plan_path):
    """For a browser whose answer is on a built request: the plan's link, and "Take back my
    answer", which a redirect would leave no way to reach. Never cached, like every /g/ page; once
    the answer is taken back, this browser is redirected to the plan like everyone else."""
    response = render(
        request,
        "plans/request_built.html",
        {"slug": group.slug, "page_url": request_url(request, group.slug), "plan_path": plan_path},
    )
    return with_page_headers(response, takes_answers=True)


def _has_own_answer(request, group) -> bool:
    return group.answers.filter(responder=_existing_responder(request, group.slug)).exists()


def _request_path(slug) -> str:
    """/g/<slug>: where answers go back to, and the cookie's path."""
    return reverse("plan-request", args=[slug])


def _existing_responder(request, slug) -> str:
    """This browser's responder hash, without giving it a cookie: a browser with no valid cookie
    gets a fresh random token's hash, which matches no answer."""
    return responder_token(request, HttpResponse(), _request_path(slug))


def _cookie_max_age(group) -> int:
    """Seconds until the day the answer is deleted (brief GS-5), at least the usual 30 days. The
    day is at most 14 days ahead, so at most 44 days."""
    days_left = (group.day - timezone.localdate()).days + REQUEST_RETENTION_DAYS
    return max(RESPONDER_COOKIE_MAX_AGE, days_left * 24 * 60 * 60)


_FORM_TIME = re.compile(r"\A([01]\d|2[0-3]):([0-5]\d)(?::[0-5]\d(?:\.\d{1,3})?)?\Z")
_FORM_BUDGET = re.compile(r"\A\d{1,3}\Z")


def _form_time(value) -> time | None:
    """A time input's value: HH:MM, or HH:MM:SS as some browsers send it (the seconds are dropped)."""
    match = _FORM_TIME.match(value or "")
    return time(int(match.group(1)), int(match.group(2))) if match else None


def _budget(value) -> int | None:
    """Whole dollars from 0 to 150 in $5 steps: one of the select's choices."""
    if not _FORM_BUDGET.match(value or ""):
        return None
    budget = int(value)
    return budget if budget in BUDGET_CHOICES else None


def _free_window(request, group) -> tuple[time, time] | None:
    """(from, until) inside the request's range, with "until" after "from" (brief GI-2)."""
    free_from = _form_time(request.POST.get("free_from"))
    free_until = _form_time(request.POST.get("free_until"))
    if free_from is None or free_until is None:
        return None
    if not group.window_start <= free_from < free_until <= group.window_end:
        return None
    return free_from, free_until


def _stars(request, group) -> list[str]:
    """The ticked places, once each, in the request's own order and spelling of their ids. Ids that
    aren't the request's places are ignored, as unknown stops are on a shared plan."""
    ticked = {value.lower() for value in request.POST.getlist("star")}
    return [place["id"] for place in group.places if place["id"].lower() in ticked]


def _typed(request, group) -> dict:
    """What the browser sent, to show the form again as it was. A value the form can't show (a
    budget that isn't one of its choices, a time that isn't one) comes back as the form's starting
    value: no budget chosen, or the request's range."""
    return {
        "name": (request.POST.get("name") or "")[:200],
        "budget": _budget(request.POST.get("budget")),
        "free_from": _form_time(request.POST.get("free_from")) or group.window_start,
        "free_until": _form_time(request.POST.get("free_until")) or group.window_end,
        "stars": set(_stars(request, group)),
    }


def _choose_times(group) -> str:
    return f'Choose times from {_range_text(group.window_start, group.window_end)}, with "until" after "from".'


# Dates and times as the page writes them, in US English like the app: "Saturday, November 28",
# "12 PM to 8 PM", "Friday, November 27 at 9 PM". The request's day and times are local to its
# own time zone, and so is the deadline as written.


def clock_text(moment: time) -> str:
    hour = moment.hour % 12 or 12
    suffix = "AM" if moment.hour < 12 else "PM"
    return f"{hour} {suffix}" if moment.minute == 0 else f"{hour}:{moment.minute:02d} {suffix}"


def day_text(day) -> str:
    return f"{day:%A}, {day:%B} {day.day}"


def deadline_text(group) -> str:
    local = group.answers_by.astimezone(ZoneInfo(group.time_zone))
    return f"{day_text(local.date())} at {clock_text(local.time())}"


def _range_text(start: time, end: time) -> str:
    return f"{clock_text(start)} to {clock_text(end)}"
