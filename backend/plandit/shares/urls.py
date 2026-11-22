from django.urls import path

from .views import ShareAnswerDetailView, ShareAnswersView, SharedPlanDetailView, SharedPlanListView

urlpatterns = [
    path("", SharedPlanListView.as_view(), name="shares"),
    path("<slug:slug>/", SharedPlanDetailView.as_view(), name="share-detail"),
    path("<slug:slug>/answers/", ShareAnswersView.as_view(), name="share-answers"),
    path("<slug:slug>/answers/<uuid:answer_id>/", ShareAnswerDetailView.as_view(), name="share-answer-detail"),
]
