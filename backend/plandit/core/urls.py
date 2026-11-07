from django.urls import path

from .views import EventsView, HealthView, MetricsView, MeView, SnapshotView, StatsView

urlpatterns = [
    path("health/", HealthView.as_view(), name="health"),
    path("me/", MeView.as_view(), name="me"),
    path("me/stats/", StatsView.as_view(), name="me-stats"),
    path("me/snapshot/", SnapshotView.as_view(), name="me-snapshot"),
    path("me/events/", EventsView.as_view(), name="me-events"),
    path("metrics/", MetricsView.as_view(), name="metrics"),
]
