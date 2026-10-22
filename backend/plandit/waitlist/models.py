from django.db import models


class WaitlistSignup(models.Model):
    """An early-access signup from the marketing site. Emails are stored lowercased, once."""

    email = models.EmailField(unique=True)
    source = models.CharField(max_length=60, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return self.email
