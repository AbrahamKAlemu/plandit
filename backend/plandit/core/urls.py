from django.urls import path

from .views import HealthView, MeView, StatsView

urlpatterns = [
    path("health/", HealthView.as_view(), name="health"),
    path("me/", MeView.as_view(), name="me"),
    path("me/stats/", StatsView.as_view(), name="me-stats"),
]
