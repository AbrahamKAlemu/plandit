"""Group plans (mode 3): one day plan on the server that up to 8 Plandit accounts edit together
(brief GE-1 to GE-10).

The plan is the app's own `DayPlan` encoding, stored as JSON with a version number. Members edit it
with compare-and-swap writes: a write names the version it started from, and only a write from the
current version is stored (plandit.groups.views). Group plans never go into the per-account
`AppSnapshot`, which is last writer wins and belongs to one person.

Nothing here refers to a profile except the group's organizer and each membership, which both go
with the account (CASCADE, brief GE-10). The edit log and the removals hold plain ids, so a write
that inserts them never waits on a profile's row when it commits (MF-E in the test plan).
"""

import secrets
import uuid

from django.db import models

from plandit.core.models import Profile

# Brief GE-1: up to 8 members, the organizer included.
MAX_MEMBERS = 8
# Brief GS-5: group plans are deleted this many days after their date.
GROUP_RETENTION_DAYS = 30
# How many edits each group keeps for naming who changed what in a 409 (MF-B, MF-C).
EDIT_LOG_KEPT = 200
INVITE_TOKEN_LENGTH = 22


def new_invite_token() -> str:
    """22 URL-safe characters (128 bits) from `secrets`: an invite grants edit access, so it can't
    be guessed. Replaced when the organizer turns the old link off (brief GE-8)."""
    return secrets.token_urlsafe(16)


class GroupPlan(models.Model):
    """A plan its members edit together. `version` goes up by one on each plan edit; the members'
    apps send it back as `baseVersion`. `members_version` goes up on each join, leave or removal, so
    the ETag (both numbers) changes when the members do (MF-D).

    Deleted with the organizer's account (brief GE-10), when the organizer ends it, or 30 days after
    `date` (brief GS-5, plandit.core.retention)."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    owner = models.ForeignKey(Profile, on_delete=models.CASCADE, related_name="group_plans")
    plan_id = models.UUIDField(help_text="The app's DayPlan id; one group per plan, so a retried create finds it.")
    date = models.DateField(db_index=True, help_text="The plan's day, in New York time, for edits and expiry.")
    data = models.JSONField(help_text="The app's DayPlan encoding, at most 64 KB and 20 stops.")
    version = models.PositiveIntegerField(default=1)
    members_version = models.PositiveIntegerField(default=1)
    invite_token = models.CharField(
        max_length=INVITE_TOKEN_LENGTH, unique=True, default=new_invite_token, editable=False
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["owner", "plan_id"], name="one_group_per_plan")]

    def __str__(self) -> str:
        return f"{self.id}: {self.date} v{self.version}"


class GroupMember(models.Model):
    """Someone in a group, the organizer included. The API addresses members by this row's id, never
    by their profile's (N-11). `display_name` is the first word of the profile's name when they
    joined, checked like a friend's first name, or "Friend"; it's the only thing other members see
    about them."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    group = models.ForeignKey(GroupPlan, on_delete=models.CASCADE, related_name="members")
    profile = models.ForeignKey(Profile, on_delete=models.CASCADE, related_name="group_memberships")
    display_name = models.CharField(max_length=30)
    joined_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["group", "profile"], name="one_membership_per_group")]

    def __str__(self) -> str:
        return f"{self.group_id}: {self.display_name}"


class GroupPlanEdit(models.Model):
    """One stored plan edit: which version it made, the app's id for it, who made it and what it
    touched. A retried PUT with a known `edit_id` answers with that version and changes nothing
    (MF-B); a 409 lists the edits after the writer's base version, with their authors' names looked
    up from the current members when read (MF-C, N-12). The latest EDIT_LOG_KEPT per group are kept.

    `member_id` is a GroupMember id, not a foreign key: the member may leave or delete their
    account, and their name then stops showing."""

    group = models.ForeignKey(GroupPlan, on_delete=models.CASCADE, related_name="edits")
    version = models.PositiveIntegerField(help_text="The version this edit made.")
    edit_id = models.UUIDField(help_text="The app's id for the edit, the same on every retry.")
    member_id = models.UUIDField(help_text="The GroupMember who made it; not a foreign key.")
    kind = models.CharField(max_length=16)
    stop_ids = models.JSONField(default=list, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["group", "edit_id"], name="one_log_entry_per_edit"),
            models.UniqueConstraint(fields=["group", "version"], name="one_edit_per_version"),
        ]

    def __str__(self) -> str:
        return f"{self.group_id} v{self.version}: {self.kind}"


class GroupRemoval(models.Model):
    """The organizer removed this profile from the group, so it can't join again with the link
    (MF-G, App Store guideline 1.2). Leaving yourself writes nothing, so you can rejoin.
    `profile_id` isn't a foreign key: a removal must not wait on the removed person's profile row."""

    group = models.ForeignKey(GroupPlan, on_delete=models.CASCADE, related_name="removals")
    profile_id = models.UUIDField()
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["group", "profile_id"], name="one_removal_per_profile")]

    def __str__(self) -> str:
        return f"{self.group_id}: removed {self.profile_id}"
