from django.apps import AppConfig


class GroupsConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "plandit.groups"
    label = "groups"

    def ready(self):
        from plandit.core import retention

        from .models import GROUP_RETENTION_DAYS, GroupPlan

        # Brief GS-5. Deleting the group deletes its members, edits and removals with it (CASCADE).
        # Locked first, as every group write and account deletion lock it (MF-E).
        retention.register(GroupPlan, "date", days=GROUP_RETENTION_DAYS, lock_first=True)
