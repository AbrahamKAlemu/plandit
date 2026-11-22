from django.urls import path

from .views import GroupPlanDetailView, GroupPlanListView

# Ids are matched as text and parsed in the view: the app sends Swift UUIDs, which are upper case,
# and a malformed id must be the same 404 as a group the caller isn't in (ISO-3).
urlpatterns = [
    path("", GroupPlanListView.as_view(), name="group-plans"),
    path("<str:group_id>/", GroupPlanDetailView.as_view(), name="group-plan-detail"),
]
