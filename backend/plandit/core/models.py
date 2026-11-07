import uuid

from django.db import models
from django.utils import timezone


class AccountDeletedError(Exception):
    """The token belongs to an account that was deleted through DELETE /api/me/."""


class ProfileManager(models.Manager):
    def get_or_create_from_claims(self, claims: dict) -> "Profile":
        """Find the profile for a verified Supabase access token, creating it on first sight.

        Raises ValueError when `sub` is not a UUID and AccountDeletedError when the account was
        deleted (its token stays valid until it expires; without this check it would come back)."""
        user_id = uuid.UUID(str(claims["sub"]))
        try:
            profile = self.get(id=user_id)
        except self.model.DoesNotExist:
            pass
        else:
            email = claims.get("email") or ""
            if email and profile.email != email:
                profile.email = email
                profile.save(update_fields=["email", "updated_at"])
            return profile

        # Create branch only: one extra query, never on the hot path.
        if DeletedAccount.objects.filter(pk=user_id).exists():
            raise AccountDeletedError(user_id)
        metadata = claims.get("user_metadata") or {}
        is_anonymous = bool(claims.get("is_anonymous", False))
        profile, _ = self.get_or_create(
            id=user_id,
            defaults={
                "email": claims.get("email") or "",
                "name": metadata.get("full_name") or metadata.get("name") or "",
                "is_anonymous": is_anonymous,
                "auth_provider": auth_provider_from_claims(claims),
                "signed_up_at": None if is_anonymous else timezone.now(),
            },
        )
        return profile


def auth_provider_from_claims(claims: dict) -> str:
    app_metadata = claims.get("app_metadata") or {}
    provider = app_metadata.get("provider") if isinstance(app_metadata, dict) else None
    return str(provider)[: Profile.AUTH_PROVIDER_MAX_LENGTH] if provider else ""


class Profile(models.Model):
    """One row per Supabase Auth user. The primary key is the Supabase `auth.users.id`."""

    AUTH_PROVIDER_MAX_LENGTH = 40

    id = models.UUIDField(primary_key=True, editable=False)
    email = models.EmailField(blank=True)
    name = models.CharField(max_length=120, blank=True)
    school = models.CharField(max_length=120, blank=True)
    home_base = models.CharField(max_length=120, blank=True)
    default_budget = models.DecimalField(max_digits=8, decimal_places=2, default=60)
    travel_modes = models.CharField(max_length=60, blank=True, default="Walk + subway")
    # Claim-derived account state, kept in sync by SupabaseJWTAuthentication (see activity.py).
    is_anonymous = models.BooleanField(default=False, help_text="Supabase anonymous sign-in (old TestFlight builds).")
    auth_provider = models.CharField(max_length=AUTH_PROVIDER_MAX_LENGTH, blank=True, default="")
    signed_up_at = models.DateTimeField(null=True, blank=True, help_text="First non-anonymous token seen.")
    last_seen_at = models.DateTimeField(null=True, blank=True)
    activated_at = models.DateTimeField(null=True, blank=True, help_text="First plan with at least one stop.")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    objects = ProfileManager()

    # Lets DRF's IsAuthenticated treat a Profile as a logged-in user without django.contrib.auth.
    # (`is_anonymous` above is a model field; DRF only reads `is_authenticated`.)
    is_authenticated = True
    is_active = True

    class Meta:
        ordering = ["created_at"]

    def __str__(self) -> str:
        return self.name or self.email or str(self.id)


class DeletedAccount(models.Model):
    """Tombstone written when DELETE /api/me/ succeeds, so the still-valid access token cannot
    re-create the Profile before it expires. Only written once Supabase confirmed the deletion."""

    id = models.UUIDField(primary_key=True, editable=False)
    deleted_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-deleted_at"]

    def __str__(self) -> str:
        return f"{self.id} deleted {self.deleted_at:%Y-%m-%d}"


class AppSnapshot(models.Model):
    """The iOS app's whole local store for one account, stored opaquely (last writer wins)."""

    profile = models.OneToOneField(Profile, on_delete=models.CASCADE, related_name="snapshot")
    data = models.JSONField(default=dict)
    version = models.PositiveIntegerField(default=0)
    saved_count = models.PositiveIntegerField(default=0)
    past_plans_count = models.PositiveIntegerField(default=0)
    today_stop_count = models.PositiveIntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self) -> str:
        return f"{self.profile_id} v{self.version}"


class ActivityDay(models.Model):
    """One row per profile per local day on which it made an authenticated API call."""

    profile = models.ForeignKey(Profile, on_delete=models.CASCADE, related_name="activity_days")
    date = models.DateField()

    class Meta:
        ordering = ["-date"]
        constraints = [models.UniqueConstraint(fields=["profile", "date"], name="core_activityday_profile_date_uniq")]

    def __str__(self) -> str:
        return f"{self.profile_id} {self.date}"


class ActivityEventName(models.TextChoices):
    LINK_SAVED = "link_saved", "Link saved"
    PLACE_SAVED = "place_saved", "Place saved"
    PLAN_BUILT = "plan_built", "Plan built"


class ActivityEvent(models.Model):
    """A usage event the app reports: link_saved, place_saved or plan_built."""

    profile = models.ForeignKey(Profile, on_delete=models.CASCADE, related_name="events")
    name = models.CharField(max_length=32, choices=ActivityEventName.choices)
    occurred_at = models.DateTimeField()
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-occurred_at"]
        indexes = [models.Index(fields=["name", "occurred_at"], name="core_event_name_time_idx")]

    def __str__(self) -> str:
        return f"{self.name} {self.occurred_at:%Y-%m-%d %H:%M}"
