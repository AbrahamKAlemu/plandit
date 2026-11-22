from django.apps import AppConfig


class SharesConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "plandit.shares"

    def ready(self):
        from plandit.core import retention

        from .models import ANSWER_RETENTION_DAYS, ShareAnswer

        retention.register(ShareAnswer, "plan_date", days=ANSWER_RETENTION_DAYS)
