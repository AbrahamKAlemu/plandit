from django.urls import path

from .views import (
    GroupInviteReplaceView,
    GroupInviteView,
    GroupJoinView,
    GroupMemberDetailView,
    GroupPlanDetailView,
    GroupPlanListView,
)

# Ids and tokens are matched as text and checked in the view: the app sends Swift UUIDs, which are
# upper case, and a malformed id must be the same 404 as a group the caller isn't in (ISO-3).
# POST paths answer with and without the trailing slash: a POST can't follow APPEND_SLASH's
# redirect (CTR-1). The app uses the spellings without it.
urlpatterns = [
    path("", GroupPlanListView.as_view(), name="group-plans"),
    path("invites/<str:token>/", GroupInviteView.as_view(), name="group-plan-invite"),
    path("invites/<str:token>/join", GroupJoinView.as_view(), name="group-plan-join"),
    path("invites/<str:token>/join/", GroupJoinView.as_view()),
    path("<str:group_id>/", GroupPlanDetailView.as_view(), name="group-plan-detail"),
    path("<str:group_id>/invite", GroupInviteReplaceView.as_view(), name="group-plan-new-invite"),
    path("<str:group_id>/invite/", GroupInviteReplaceView.as_view()),
    path("<str:group_id>/members/<str:member_id>/", GroupMemberDetailView.as_view(), name="group-plan-member"),
]
