from datetime import datetime, time

from django.db import transaction
from django.shortcuts import get_object_or_404
from django.utils import timezone
from rest_framework import serializers, status, viewsets
from rest_framework.decorators import action
from rest_framework.response import Response

from plandit.places.models import Place
from plandit.saved.models import SavedPost

from . import services
from .models import DayPlan, PlanStop
from .serializers import (
    AddStopSerializer,
    BuildPlanSerializer,
    DayPlanSerializer,
    DayPlanSummarySerializer,
    DayPlanWriteSerializer,
    PlanStopSerializer,
    ReorderSerializer,
)


class DayPlanViewSet(viewsets.ModelViewSet):
    """
    GET    /api/plans/                         the caller's plans, newest first (summaries)
    POST   /api/plans/                         {"date", "title", "budget"} all optional
    GET    /api/plans/today/                   today's plan, created on first call
    GET    /api/plans/<id>/                    full plan with stops and legs
    PATCH  /api/plans/<id>/                    date, title, budget
    DELETE /api/plans/<id>/
    POST   /api/plans/<id>/stops/              {"saved_post_id"} or {"place_id"}
                                               (+ start, duration_minutes, estimated_cost, note)
    POST   /api/plans/<id>/stops/reorder/      {"stop_ids": [...]}
    POST   /api/plans/<id>/build/              {"saved_post_ids", "start", "end", "budget", "mode": "add"|"replace",
                                               "dry_run"}: the planner orders, times and budgets the day.
                                               Adds "skipped": [{name, place_id, saved_post_id, stop_id, reason}].
    PATCH  /api/plans/<id>/stops/<stop_id>/    status, start, duration_minutes, estimated_cost, note
    DELETE /api/plans/<id>/stops/<stop_id>/
    Every mutation returns the full plan.
    """

    http_method_names = ["get", "post", "patch", "delete", "head", "options"]

    def get_queryset(self):
        return DayPlan.objects.filter(owner=self.request.user).prefetch_related("stops__place", "legs")

    def get_serializer_class(self):
        if self.action == "list":
            return DayPlanSummarySerializer
        if self.action in {"create", "partial_update"}:
            return DayPlanWriteSerializer
        return DayPlanSerializer

    def _full(self, plan: DayPlan, http_status=status.HTTP_200_OK) -> Response:
        plan = self.get_queryset().get(pk=plan.pk)  # re-fetch so prefetches reflect the mutation
        return Response(DayPlanSerializer(plan).data, status=http_status)

    def create(self, request, *args, **kwargs):
        serializer = DayPlanWriteSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data
        date = data.get("date") or timezone.localdate()
        if DayPlan.objects.filter(owner=request.user, date=date).exists():
            raise serializers.ValidationError({"date": "You already have a plan for this date."})
        plan = DayPlan.objects.create(
            owner=request.user,
            date=date,
            title=data.get("title") or "Today",
            budget=data.get("budget", request.user.default_budget),
        )
        return self._full(plan, status.HTTP_201_CREATED)

    def partial_update(self, request, *args, **kwargs):
        plan = self.get_object()
        serializer = DayPlanWriteSerializer(plan, data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        new_date = serializer.validated_data.get("date")
        if new_date and new_date != plan.date and DayPlan.objects.filter(owner=request.user, date=new_date).exists():
            raise serializers.ValidationError({"date": "You already have a plan for this date."})
        serializer.save()
        return self._full(plan)

    @action(detail=False, methods=["get"])
    def today(self, request):
        return self._full(services.get_or_create_today(request.user))

    @action(detail=True, methods=["post"])
    def stops(self, request, pk=None):
        plan = self.get_object()
        serializer = AddStopSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        source_post = None
        note = data.get("note", "")
        estimated_cost = data.get("estimated_cost")
        if "saved_post_id" in data:
            source_post = get_object_or_404(SavedPost, pk=data["saved_post_id"], owner=request.user)
            if not source_post.is_mappable:
                raise serializers.ValidationError({"saved_post_id": "This post has no place yet."})
            if plan.stops.filter(source_post=source_post).exists():
                raise serializers.ValidationError({"saved_post_id": "This post is already in the plan."})
            place = source_post.place
            if estimated_cost is None:
                estimated_cost = source_post.estimated_cost
            if not note:
                note = f"Added from your saved {source_post.get_platform_display()} post."
        else:
            place = get_object_or_404(Place, pk=data["place_id"])

        services.append_stop(
            plan,
            place=place,
            duration_minutes=data.get("duration_minutes", 60),
            estimated_cost=estimated_cost,
            note=note,
            source_post=source_post,
            start=data.get("start"),
        )
        return self._full(plan, status.HTTP_201_CREATED)

    @action(detail=True, methods=["post"], url_path="stops/reorder")
    def reorder(self, request, pk=None):
        plan = self.get_object()
        serializer = ReorderSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            services.reorder_stops(plan, serializer.validated_data["stop_ids"])
        except ValueError as exc:
            raise serializers.ValidationError({"stop_ids": str(exc)}) from exc
        return self._full(plan)

    @action(detail=True, methods=["patch", "delete"], url_path=r"stops/(?P<stop_id>[0-9a-fA-F-]{36})")
    def stop(self, request, pk=None, stop_id=None):
        plan = self.get_object()
        stop = get_object_or_404(PlanStop, pk=stop_id, plan=plan)
        if request.method == "DELETE":
            services.remove_stop(plan, stop)
            return self._full(plan)
        serializer = PlanStopSerializer(stop, data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return self._full(plan)

    @action(detail=True, methods=["post"])
    def build(self, request, pk=None):
        plan = self.get_object()
        serializer = BuildPlanSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        ids = list(dict.fromkeys(data["saved_post_ids"]))
        posts = {p.id: p for p in SavedPost.objects.filter(owner=request.user, id__in=ids).select_related("place")}
        if missing := [str(i) for i in ids if i not in posts]:
            raise serializers.ValidationError({"saved_post_ids": f"Unknown saved posts: {', '.join(missing)}."})
        if unmapped := [str(i) for i in ids if not posts[i].is_mappable]:
            raise serializers.ValidationError(
                {"saved_post_ids": f"These posts have no place yet: {', '.join(unmapped)}."}
            )

        start = data.get("start")
        if start is None:
            today = timezone.localdate()
            start = (
                timezone.now()
                if plan.date == today
                else timezone.make_aware(datetime.combine(plan.date, time(10)))  # a future day starts at 10 AM
            )

        with transaction.atomic():
            result = services.build_plan(
                plan,
                saved_posts=[posts[i] for i in ids],
                start=start,
                budget=data.get("budget", plan.budget),
                mode=data["mode"],
                end=data.get("end"),
            )
            body = DayPlanSerializer(self.get_queryset().get(pk=plan.pk)).data
            if data["dry_run"]:
                transaction.set_rollback(True)

        body["skipped"] = [
            {
                "name": skip.candidate.place.name,
                "place_id": str(skip.candidate.place.id),
                "saved_post_id": str(skip.candidate.key.id) if isinstance(skip.candidate.key, SavedPost) else None,
                "stop_id": str(skip.candidate.key.id) if isinstance(skip.candidate.key, PlanStop) else None,
                "reason": skip.reason,
            }
            for skip in result.outcome.skipped
        ]
        return Response(body)
