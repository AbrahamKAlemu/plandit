import logging
from datetime import UTC, date, timedelta
from urllib.parse import urlencode

from django.conf import settings
from django.core.exceptions import ValidationError
from django.db import transaction
from django.http import Http404, HttpResponse, HttpResponseRedirect
from django.shortcuts import render
from django.urls import reverse
from django.utils import timezone
from django.views.decorators.http import require_POST
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from plandit.core.public_forms import (
    clean_first_name,
    client_ip,
    describe_forwarding,
    public_page_csp,
    rate_limited,
    responder_token,
)
from plandit.core.retention import purge_expired

from .models import ANSWER_RETENTION_DAYS, ShareAnswer, SharedPlan
from .serializers import SharedPlanSerializer

logger = logging.getLogger(__name__)

# Brief GS-2. The address limit counts every answer posted from one address, on any link; the
# link cap is a count of the link's answers in the database (a rate limit's cache can evict live
# counts once it's full).
ANSWERS_PER_ADDRESS = 20
ANSWERS_PER_ADDRESS_WINDOW = 60 * 60
ANSWERS_PER_LINK = 50
# Brief GV-3: the page names at most this many of the friends who are in.
NAMES_SHOWN = 3

TRY_LATER = "Too many answers right now. Please try again later."
CHOOSE_A_BUTTON = "Choose “I'm in” or “Can't make it”."


def share_url(request, slug: str) -> str:
    """plandit.app/p/<slug> once the site forwards /p/ here (SHARE_BASE_URL); until then this API's own host."""
    base = getattr(settings, "SHARE_BASE_URL", "") or request.build_absolute_uri("/").rstrip("/")
    return f"{base.rstrip('/')}/p/{slug}"


class SharedPlanListView(APIView):
    """POST /api/shares/: share a plan, or update its existing link. 201 the first time, 200 after.

    Updating keeps friends' answers (brief GV-8), minus their swaps for stops no longer in the plan."""

    def post(self, request):
        serializer = SharedPlanSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = dict(serializer.validated_data)
        plan_id = data.pop("planId")
        with transaction.atomic():
            # update_or_create locks the link's row, as answering does, so an answer can't be saved
            # against the old stops while this replaces them.
            shared, created = SharedPlan.objects.update_or_create(
                owner=request.user, plan_id=plan_id, defaults={"data": _jsonable(data)}
            )
            if not created:
                _keep_answers_in_step(shared)
        return Response(
            {"slug": shared.slug, "url": share_url(request, shared.slug)},
            status=status.HTTP_201_CREATED if created else status.HTTP_200_OK,
        )


class SharedPlanDetailView(APIView):
    """DELETE /api/shares/<slug>/: stop sharing. The link stops working at once, and friends'
    answers go with it (brief GV-10). Only the owner can; anyone else gets 404, so a slug's
    existence isn't revealed."""

    def delete(self, request, slug):
        with transaction.atomic():
            # Lock the link first. A friend's answer is saved with this lock held, so the delete
            # waits for it and takes it along, instead of missing it and failing at commit.
            shared = SharedPlan.objects.select_for_update().filter(slug=slug, owner=request.user).first()
            if shared is None:
                return Response(status=status.HTTP_404_NOT_FOUND)
            shared.delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


class ShareAnswersView(APIView):
    """GET /api/shares/<slug>/answers/: every friend's answer on the owner's link, oldest first.
    Anyone else gets 404."""

    def get(self, request, slug):
        purge_expired()
        shared = SharedPlan.objects.filter(slug=slug, owner=request.user).first()
        if shared is None:
            return Response(status=status.HTTP_404_NOT_FOUND)
        answers = shared.answers.order_by("created_at", "id")
        return Response({"answers": [_answer_json(answer) for answer in answers]})


class ShareAnswerDetailView(APIView):
    """DELETE /api/shares/<slug>/answers/<id>/: the owner removes an answer (brief GV-7). It's gone
    from the page at once. Anyone else gets 404."""

    def delete(self, request, slug, answer_id):
        deleted, _ = ShareAnswer.objects.filter(
            id=answer_id, shared_plan__slug=slug, shared_plan__owner=request.user
        ).delete()
        return Response(status=status.HTTP_204_NO_CONTENT if deleted else status.HTTP_404_NOT_FOUND)


# --- The public page ------------------------------------------------------------------------


@public_page_csp
def shared_plan_page(request, slug):
    """GET /p/<slug>: the public page friends open. No sign-in. Plans shared with `answers: true`
    also get the answer form (brief GV-1 to GV-4)."""
    # Temporary: the proxy chain's shape, no addresses, to measure TRUSTED_PROXY_HOPS (slice G1a).
    logger.info("proxy chain: %s", describe_forwarding(request))
    shared = SharedPlan.objects.filter(slug=slug).first()
    if shared is None:
        return _not_found_page(request)
    if _takes_answers(shared):
        purge_expired()
    return _plan_page(request, shared)


@public_page_csp
@require_POST
def answer_plan(request, slug):
    """POST /p/<slug>/answer: a friend's answer, from the page's form. Django's CSRF check runs
    first. Then the address limit, the first name and the buttons; then, with the link locked,
    the per-link cap and the save, matched to the browser by its cookie. 303 back to the page.
    Over a limit (429) or with a bad name (400), the page comes back with the reason."""
    shared = SharedPlan.objects.filter(slug=slug).first()
    if shared is None:
        return _not_found_page(request)
    if not _takes_answers(shared):
        raise Http404
    if rate_limited(f"answer-address:{client_ip(request)}", ANSWERS_PER_ADDRESS, ANSWERS_PER_ADDRESS_WINDOW):
        return _plan_page(request, shared, form=_typed(request, shared), error=TRY_LATER, status=429)
    # After the limit, so a refused request costs as little as possible.
    purge_expired()

    form = _typed(request, shared)
    try:
        form["name"] = clean_first_name(request.POST.get("name"))
    except ValidationError as error:
        return _plan_page(request, shared, form=form, error=error.messages[0], name_invalid=True, status=400)
    if form["status"] not in ShareAnswer.Status.values:
        return _plan_page(request, shared, form=form, error=CHOOSE_A_BUTTON, status=400)

    response = _with_page_headers(HttpResponseRedirect(_page_path(slug), status=303), takes_answers=True)
    responder = responder_token(request, response, _page_path(slug))
    with transaction.atomic():
        shared = SharedPlan.objects.select_for_update().filter(pk=shared.pk).first()
        if shared is None:
            return _not_found_page(request)
        if not _takes_answers(shared):
            raise Http404
        answers = shared.answers.all()
        if not answers.filter(responder=responder).exists() and answers.count() >= ANSWERS_PER_LINK:
            return _plan_page(request, shared, form=form, error=TRY_LATER, status=429)
        ShareAnswer.objects.update_or_create(
            shared_plan=shared,
            responder=responder,
            defaults={
                "name": form["name"],
                "status": form["status"],
                # Checked against the plan as it is now, under the lock.
                "swaps": _picked_swaps(request, shared),
                "plan_date": _plan_date(shared),
            },
        )
    return response


@public_page_csp
@require_POST
def take_back_answer(request, slug):
    """POST /p/<slug>/answer/delete: the browser takes back its own answer (brief GV-4). Not rate
    limited: it can only remove what this browser's cookie wrote. 303 back to the page."""
    shared = SharedPlan.objects.filter(slug=slug).first()
    if shared is None:
        return _not_found_page(request)
    if not _takes_answers(shared):
        raise Http404
    purge_expired()
    responder = _existing_responder(request, slug)
    ShareAnswer.objects.filter(shared_plan=shared, responder=responder).delete()
    return _with_page_headers(HttpResponseRedirect(_page_path(slug), status=303), takes_answers=True)


def _not_found_page(request):
    """A link that doesn't exist, or stopped being shared while the page was open. (A link shared
    without answers answers the answer POSTs with a bare 404 instead, so nothing is collected before
    the app asks for it.)"""
    return _with_page_headers(render(request, "shares/not_found.html", status=404), takes_answers=False)


def _plan_page(request, shared, *, form=None, error="", name_invalid=False, status=200):
    """The page itself. With answers on: who's in, each stop's "I'd swap this", and the form, with
    this browser's own answer (or what it just typed, when `form` comes back with an `error`)."""
    plan = shared.data
    legs = plan.get("legs") or []
    takes_answers = _takes_answers(shared)
    own = None
    going = ""
    if takes_answers:
        own = shared.answers.filter(responder=_existing_responder(request, shared.slug)).first()
        going = _going_line(shared)
    shown = form or (
        {"name": own.name, "status": own.status, "swaps": own.swaps} if own else {"name": "", "status": "", "swaps": {}}
    )
    # Each stop carries the trip that follows it ("22 min walk"); the last has none.
    stops = []
    for i, stop in enumerate(plan["stops"]):
        entry = {**stop, "maps_url": _maps_url(stop), "leg": legs[i]["text"] if i < len(legs) else None}
        if takes_answers and stop.get("id"):
            entry["swap_checked"] = stop["id"] in shown["swaps"]
            entry["swap_pick"] = shown["swaps"].get(stop["id"])
            entry["alternates"] = [
                {**alternate, "details": " · ".join(filter(None, [alternate.get(k) for k in _ALTERNATE_DETAILS]))}
                for alternate in stop.get("alternates") or []
            ]
        else:
            entry.pop("id", None)
            entry.pop("alternates", None)
        stops.append(entry)
    names = [stop["name"] for stop in plan["stops"]]
    preview = ", ".join(names[:3]) + (f" and {len(names) - 3} more" if len(names) > 3 else "")
    response = render(
        request,
        "shares/plan.html",
        {
            "plan": plan,
            "stops": stops,
            "stop_count": len(stops),
            "description": f"{plan['dateText']} · {len(stops)} {'stop' if len(stops) == 1 else 'stops'}: {preview}",
            "page_url": share_url(request, shared.slug),
            "slug": shared.slug,
            "takes_answers": takes_answers,
            "going": going,
            "own": own,
            "form": shown,
            "error": error,
            "name_invalid": name_invalid,
        },
        status=status,
    )
    return _with_page_headers(response, takes_answers=takes_answers)


_ALTERNATE_DETAILS = ("kind", "neighborhood", "costText")


def _with_page_headers(response, *, takes_answers: bool):
    response["X-Robots-Tag"] = "noindex, nofollow"
    if takes_answers:
        # The page depends on the browser's cookie and carries a CSRF token, so nothing may keep it.
        # `same-origin`, not `no-referrer`: with no referrer, browsers post the form with
        # `Origin: null`, which Django's CSRF check refuses. Other sites still get no referrer.
        response["Cache-Control"] = "private, no-store"
        response["Referrer-Policy"] = "same-origin"
    else:
        response["Cache-Control"] = "public, max-age=60"
        response["Referrer-Policy"] = "no-referrer"
    return response


def _takes_answers(shared) -> bool:
    """Shared with `answers: true` (the G1b app), with a date, and not yet past the date answers
    are deleted after (brief GS-5): an answer that would be deleted at once isn't taken."""
    plan_date = _plan_date(shared)
    if shared.data.get("answers") is not True or plan_date is None:
        return False
    return plan_date > timezone.localdate() - timedelta(days=ANSWER_RETENTION_DAYS)


def _plan_date(shared) -> date | None:
    try:
        return date.fromisoformat(shared.data.get("date") or "")
    except (TypeError, ValueError):
        return None


def _page_path(slug) -> str:
    """/p/<slug>: where answers go back to, and the cookie's path."""
    return reverse("shared-plan", args=[slug])


def _existing_responder(request, slug) -> str:
    """This browser's responder hash, without giving it a cookie: a browser with no valid cookie
    gets a fresh random token's hash, which matches no answer."""
    return responder_token(request, HttpResponse(), _page_path(slug))


def _typed(request, shared) -> dict:
    """What the browser sent, to show the form again as it was."""
    return {
        "name": (request.POST.get("name") or "")[:200],
        "status": request.POST.get("status") or "",
        "swaps": _picked_swaps(request, shared),
    }


def _picked_swaps(request, shared) -> dict:
    """{stop id: alternate id or None} from the form: a stop's "I'd swap this" box, and the
    alternate picked for it if the organizer offered that one for that stop (brief GV-2, GV-9).
    Ids that aren't in the plan are ignored."""
    offered = _offered_alternates(shared.data)
    picked = {}
    for stop_id in request.POST.getlist("swap"):
        if stop_id in offered:
            alternate = request.POST.get(f"swap_to_{stop_id}")
            picked[stop_id] = alternate if alternate in offered[stop_id] else None
    return picked


def _offered_alternates(plan: dict) -> dict[str, set[str]]:
    return {
        stop["id"]: {alternate["id"] for alternate in stop.get("alternates") or []}
        for stop in plan.get("stops") or []
        if stop.get("id")
    }


def _keep_answers_in_step(shared):
    """After the plan is updated (brief GV-8): swaps for stops that left the plan are dropped, a
    pick the organizer no longer offers becomes a plain "I'd swap this", and answers follow the
    plan's new date for expiry."""
    offered = _offered_alternates(shared.data)
    changed = []
    for answer in shared.answers.all():
        swaps = {
            stop_id: (alternate if alternate in offered[stop_id] else None)
            for stop_id, alternate in answer.swaps.items()
            if stop_id in offered
        }
        if swaps != answer.swaps:
            answer.swaps = swaps
            changed.append(answer)
    ShareAnswer.objects.bulk_update(changed, ["swaps"])
    plan_date = _plan_date(shared)
    if plan_date is not None:
        shared.answers.exclude(plan_date=plan_date).update(plan_date=plan_date)


def _going_line(shared) -> str:
    """ "Maya, Jordan and Sam are in", "Maya, Jordan, Sam and 2 more are in" (brief GV-3). Only
    friends who are in: the names of those who can't make it are never read for the page."""
    going = shared.answers.filter(status=ShareAnswer.Status.IN)
    count = going.count()
    if not count:
        return ""
    names = list(going.order_by("created_at", "id").values_list("name", flat=True)[:NAMES_SHOWN])
    if count > len(names):
        listed = f"{', '.join(names)} and {count - len(names)} more"
    elif count == 1:
        listed = names[0]
    else:
        listed = f"{', '.join(names[:-1])} and {names[-1]}"
    return f"{listed} {'is' if count == 1 else 'are'} in"


def _answer_json(answer) -> dict:
    return {
        "id": str(answer.id),
        "name": answer.name,
        "status": answer.status,
        "swaps": answer.swaps,
        "createdAt": _utc(answer.created_at),
        "updatedAt": _utc(answer.updated_at),
    }


def _utc(moment) -> str:
    """Whole seconds in UTC with a Z, which Swift's .iso8601 date decoding reads."""
    return moment.astimezone(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def _maps_url(stop: dict) -> str:
    """Apple Maps: opens the Maps app on iPhone and maps.apple.com anywhere else."""
    query = {"q": stop["name"]}
    if stop.get("latitude") is not None and stop.get("longitude") is not None:
        query["ll"] = f"{stop['latitude']},{stop['longitude']}"
    elif stop.get("address"):
        query["address"] = stop["address"]
    return "https://maps.apple.com/?" + urlencode(query)


def _jsonable(value):
    """validated_data holds OrderedDicts, floats and the plan's date; store plain JSON."""
    if isinstance(value, dict):
        return {k: _jsonable(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_jsonable(v) for v in value]
    if isinstance(value, date):
        return value.isoformat()
    return value
