from django.apps import AppConfig


class PlansConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "plandit.plans"
    label = "plans"

    def ready(self):
        from plandit.core import retention

        from .models import REQUEST_RETENTION_DAYS, GroupRequest

        # Brief GS-5. Deleting the request deletes its answers with it (CASCADE). Locked first, as
        # account deletion, the organizer's delete and a friend's answer lock it before its answers.
        retention.register(GroupRequest, "day", days=REQUEST_RETENTION_DAYS, lock_first=True)
