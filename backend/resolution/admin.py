from django.contrib import admin

from .models import ResolutionAttempt


@admin.register(ResolutionAttempt)
class ResolutionAttemptAdmin(admin.ModelAdmin):
    list_display = (
        "request_id",
        "platform",
        "outcome",
        "provider",
        "candidate_count",
        "latency_ms",
        "created_at",
    )
    list_filter = ("platform", "outcome", "provider")
    search_fields = ("request_id", "idempotency_digest")
    readonly_fields = (
        "request_id",
        "platform",
        "outcome",
        "provider",
        "candidate_count",
        "latency_ms",
        "idempotency_digest",
        "created_at",
    )
