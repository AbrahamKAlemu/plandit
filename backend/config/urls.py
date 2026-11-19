from django.contrib import admin
from django.urls import include, path

from plandit.shares.views import shared_plan_page

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/", include("plandit.core.urls")),
    path("api/places/", include("plandit.places.urls")),
    path("api/saved/", include("plandit.saved.urls")),
    path("api/plans/", include("plandit.plans.urls")),
    path("api/waitlist/", include("plandit.waitlist.urls")),
    path("api/shares/", include("plandit.shares.urls")),
    path("p/<slug:slug>", shared_plan_page, name="shared-plan"),
    path("v1/", include("resolution.urls")),
]
