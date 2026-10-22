from django.urls import path

from .views import place_resolutions, social_evidence

urlpatterns = [
    path("place-resolutions", place_resolutions, name="place-resolutions"),
    path("social-evidence", social_evidence, name="social-evidence"),
]
