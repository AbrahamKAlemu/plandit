"""
Per-request account bookkeeping, run by SupabaseJWTAuthentication after the token is verified.

Two jobs:
- keep the claim-derived Profile fields (`is_anonymous`, `auth_provider`, `signed_up_at`) in
  step with what the token says;
- record that the account was active today (`Profile.last_seen_at` and one `ActivityDay` per
  local day), at most once per ACTIVITY_INTERVAL so a busy session costs one write, not hundreds.

Everything here is best effort and uses `.update()` so it never races with the request's own
`profile.save()`. Anonymous profiles get activity rows too; the metrics filter them out.
"""

from datetime import timedelta

from django.utils import timezone

from .models import ActivityDay, Profile, auth_provider_from_claims

ACTIVITY_INTERVAL = timedelta(minutes=5)


def sync_profile(profile: Profile, claims: dict) -> None:
    """Sync claim-derived fields and record activity for one authenticated request."""
    now = timezone.now()
    sync_claims(profile, claims, now=now)
    record_activity(profile, now=now)


def sync_claims(profile: Profile, claims: dict, *, now=None) -> bool:
    """Update `is_anonymous`, `auth_provider` and `signed_up_at` from the token. True if written."""
    now = now or timezone.now()
    updates = {}
    is_anonymous = bool(claims.get("is_anonymous", False))
    # One way only: an anonymous session that links an email becomes a signup, but a later
    # anonymous token for the same user never demotes it.
    if profile.is_anonymous and not is_anonymous:
        updates["is_anonymous"] = False
    provider = auth_provider_from_claims(claims)
    if provider and profile.auth_provider != provider:
        updates["auth_provider"] = provider
    if not is_anonymous and profile.signed_up_at is None:
        updates["signed_up_at"] = now
    if not updates:
        return False
    updates["updated_at"] = now
    Profile.objects.filter(pk=profile.pk).update(**updates)
    for field, value in updates.items():
        setattr(profile, field, value)
    return True


def record_activity(profile: Profile, *, now=None) -> bool:
    """Mark the profile active now unless it was already marked within ACTIVITY_INTERVAL today.
    Returns True when something was written."""
    now = now or timezone.now()
    today = timezone.localdate(now)
    last_seen = profile.last_seen_at
    if last_seen is not None and now - last_seen < ACTIVITY_INTERVAL and timezone.localdate(last_seen) == today:
        return False
    Profile.objects.filter(pk=profile.pk).update(last_seen_at=now)
    profile.last_seen_at = now
    # get_or_create already absorbs the unique-constraint race (two requests, same day) by
    # catching the IntegrityError inside a savepoint and re-fetching.
    ActivityDay.objects.get_or_create(profile=profile, date=today)
    return True
