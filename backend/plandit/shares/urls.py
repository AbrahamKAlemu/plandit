from django.urls import path

from .views import SharedPlanDetailView, SharedPlanListView

urlpatterns = [
    path("", SharedPlanListView.as_view(), name="shares"),
    path("<slug:slug>/", SharedPlanDetailView.as_view(), name="share-detail"),
]
