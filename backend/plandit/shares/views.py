from urllib.parse import urlencode

from django.conf import settings
from django.shortcuts import render
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import SharedPlan
from .serializers import SharedPlanSerializer


def share_url(request, slug: str) -> str:
    """plandit.app/p/<slug> once the site forwards /p/ here (SHARE_BASE_URL); until then this API's own host."""
    base = getattr(settings, "SHARE_BASE_URL", "") or request.build_absolute_uri("/").rstrip("/")
    return f"{base.rstrip('/')}/p/{slug}"


class SharedPlanListView(APIView):
    """POST /api/shares/: share a plan, or update its existing link. 201 the first time, 200 after."""

    def post(self, request):
        serializer = SharedPlanSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = dict(serializer.validated_data)
        plan_id = data.pop("planId")
        shared, created = SharedPlan.objects.update_or_create(
            owner=request.user, plan_id=plan_id, defaults={"data": _jsonable(data)}
        )
        return Response(
            {"slug": shared.slug, "url": share_url(request, shared.slug)},
            status=status.HTTP_201_CREATED if created else status.HTTP_200_OK,
        )


class SharedPlanDetailView(APIView):
    """DELETE /api/shares/<slug>/: stop sharing. The link stops working at once. Only the owner can;
    anyone else gets 404, so a slug's existence isn't revealed."""

    def delete(self, request, slug):
        deleted, _ = SharedPlan.objects.filter(slug=slug, owner=request.user).delete()
        return Response(status=status.HTTP_204_NO_CONTENT if deleted else status.HTTP_404_NOT_FOUND)


def shared_plan_page(request, slug):
    """GET /p/<slug>: the public page friends open. No sign-in."""
    shared = SharedPlan.objects.filter(slug=slug).first()
    if shared is None:
        response = render(request, "shares/not_found.html", status=404)
    else:
        plan = shared.data
        legs = plan.get("legs") or []
        # Each stop carries the trip that follows it ("22 min walk"); the last has none.
        stops = [
            {**stop, "maps_url": _maps_url(stop), "leg": legs[i]["text"] if i < len(legs) else None}
            for i, stop in enumerate(plan["stops"])
        ]
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
                "page_url": share_url(request, slug),
            },
        )
    response["X-Robots-Tag"] = "noindex, nofollow"
    response["Cache-Control"] = "public, max-age=60"
    response["Referrer-Policy"] = "no-referrer"
    return response


def _maps_url(stop: dict) -> str:
    """Apple Maps: opens the Maps app on iPhone and maps.apple.com anywhere else."""
    query = {"q": stop["name"]}
    if stop.get("latitude") is not None and stop.get("longitude") is not None:
        query["ll"] = f"{stop['latitude']},{stop['longitude']}"
    elif stop.get("address"):
        query["address"] = stop["address"]
    return "https://maps.apple.com/?" + urlencode(query)


def _jsonable(value):
    """validated_data holds OrderedDicts and floats; store plain JSON."""
    if isinstance(value, dict):
        return {k: _jsonable(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_jsonable(v) for v in value]
    return value
