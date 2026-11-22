from django.urls import path

from .views import ShareAnswerDetailView, ShareAnswersView, SharedPlanDetailView, SharedPlanListView

urlpatterns = [
    path("", SharedPlanListView.as_view(), name="shares"),
    path("<slug:slug>/", SharedPlanDetailView.as_view(), name="share-detail"),
    path("<slug:slug>/answers/", ShareAnswersView.as_view(), name="share-answers"),
    # Not <uuid:>, which only matches lower case: the app sends upper case. The view checks the id.
    path("<slug:slug>/answers/<str:answer_id>/", ShareAnswerDetailView.as_view(), name="share-answer-detail"),
]
