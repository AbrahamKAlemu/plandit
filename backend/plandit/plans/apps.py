from django.apps import AppConfig


class PlansConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "plandit.plans"
    label = "plans"

    def ready(self):
        from plandit.core import retention

        from .models import REQUEST_RETENTION_DAYS, GroupRequest

        # Brief GS-5. Deleting the request deletes its answers with it (CASCADE).
        retention.register(GroupRequest, "day", days=REQUEST_RETENTION_DAYS)
