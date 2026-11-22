from django.contrib import admin
from django.urls import include, path

from plandit.plans.request_views import answer_request, request_page, take_back_request_answer
from plandit.shares.views import answer_plan, shared_plan_page, take_back_answer

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/", include("plandit.core.urls")),
    path("api/places/", include("plandit.places.urls")),
    path("api/saved/", include("plandit.saved.urls")),
    path("api/plans/", include("plandit.plans.urls")),
    path("api/waitlist/", include("plandit.waitlist.urls")),
    path("api/shares/", include("plandit.shares.urls")),
    path("api/plan-requests/", include("plandit.plans.request_urls")),
    path("api/group-plans/", include("plandit.groups.urls")),
    path("p/<slug:slug>", shared_plan_page, name="shared-plan"),
    path("p/<slug:slug>/answer", answer_plan, name="shared-plan-answer"),
    path("p/<slug:slug>/answer/delete", take_back_answer, name="shared-plan-answer-delete"),
    path("g/<slug:slug>", request_page, name="plan-request"),
    path("g/<slug:slug>/answer", answer_request, name="plan-request-answer"),
    path("g/<slug:slug>/answer/delete", take_back_request_answer, name="plan-request-answer-delete"),
    path("v1/", include("resolution.urls")),
]
