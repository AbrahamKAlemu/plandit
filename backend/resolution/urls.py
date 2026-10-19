from django.urls import path

from .views import place_resolutions

urlpatterns = [
    path("place-resolutions", place_resolutions, name="place-resolutions"),
]
