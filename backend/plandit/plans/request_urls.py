from django.urls import path

from .request_views import PlanRequestAnswerDetailView, PlanRequestCloseView, PlanRequestDetailView, PlanRequestListView

urlpatterns = [
    path("", PlanRequestListView.as_view(), name="plan-requests"),
    path("<slug:slug>/", PlanRequestDetailView.as_view(), name="plan-request-detail"),
    path("<slug:slug>/close/", PlanRequestCloseView.as_view(), name="plan-request-close"),
    # Also without the slash, as the architecture writes it: a POST can't follow APPEND_SLASH's redirect.
    path("<slug:slug>/close", PlanRequestCloseView.as_view()),
    # Not <uuid:>, which only matches lower case: the app sends upper case. The view checks the id.
    path(
        "<slug:slug>/answers/<str:answer_id>/", PlanRequestAnswerDetailView.as_view(), name="plan-request-answer-detail"
    ),
]
