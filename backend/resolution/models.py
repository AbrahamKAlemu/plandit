from django.db import models

from plandit.core.models import Profile


class ResolutionAttempt(models.Model):
    request_id = models.UUIDField(unique=True)
    platform = models.CharField(max_length=16)
    outcome = models.CharField(max_length=32)
    provider = models.CharField(max_length=32, default="fixture")
    candidate_count = models.PositiveSmallIntegerField(default=0)
    latency_ms = models.PositiveIntegerField(default=0)
    idempotency_digest = models.CharField(max_length=64)
    candidate_payload = models.JSONField(null=True, default=None)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.request_id} {self.platform} {self.outcome}"


class SocialEvidenceThrottleState(models.Model):
    user = models.OneToOneField(Profile, on_delete=models.CASCADE, primary_key=True)
    window_started_at = models.DateTimeField()
    request_count = models.PositiveIntegerField(default=0)
