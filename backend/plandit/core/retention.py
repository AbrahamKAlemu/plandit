"""How long data from people who aren't users is kept (brief GS-5): friends' answers 30 days after
the plan's date, group plans 30 days after theirs.

This is the one place those limits live. Each app registers its tables when it loads, for example
in its AppConfig.ready():

    retention.register(GroupRequest, "day", days=30)

`purge_expired()` then deletes every row at or past its limit. Later slices call it at the start of
each public answer POST and owner GET, and `manage.py purge_expired` runs it by hand or on a
schedule. Until a slice registers a table, it deletes nothing.

A table whose writes lock its rows before changing what hangs off them (group plans) registers
with `lock_first=True`: the purge then locks the expired rows in primary-key order, as those
writes and account deletion do, before the cascade, in one transaction. Deleting the children
first and the row last would wait on a write that holds the row and waits for those children.
"""

from dataclasses import dataclass
from datetime import date, datetime, timedelta

from django.db import models, transaction
from django.utils import timezone


@dataclass(frozen=True)
class ExpiryRule:
    """Delete rows of `model` once `date_field` is `days` or more days in the past."""

    model: type[models.Model]
    date_field: str
    days: int
    lock_first: bool = False

    @property
    def label(self) -> str:
        return f"{self.model._meta.label}.{self.date_field}"

    def purge(self, now: datetime) -> int:
        field = self.model._meta.get_field(self.date_field)
        limit = cutoff(field, now, self.days)
        expired = self.model._default_manager.filter(**{f"{self.date_field}__lte": limit})
        if not self.lock_first:
            deleted, _ = expired.delete()
            return deleted
        with transaction.atomic():
            keys = lock_rows(expired)
            deleted, _ = self.model._default_manager.filter(pk__in=keys).delete()
        return deleted


def lock_rows(queryset) -> list:
    """Row-lock the queryset's rows in primary-key order; returns their keys. Call inside a
    transaction. Its own function so the race tests can hold the purge right after it."""
    return list(queryset.select_for_update().order_by("pk").values_list("pk", flat=True))


RULES: list[ExpiryRule] = []


def register(model: type[models.Model], date_field: str, days: int, *, lock_first: bool = False) -> ExpiryRule:
    """Add an expiry rule. Fails at once if the field doesn't exist or `days` isn't positive."""
    model._meta.get_field(date_field)
    if days <= 0:
        raise ValueError("days must be positive")
    rule = ExpiryRule(model, date_field, days, lock_first)
    RULES.append(rule)
    return rule


def cutoff(field: models.Field, now: datetime, days: int) -> datetime | date:
    """The newest value that has expired: a moment for a DateTimeField, and for a DateField (a
    plan's day) the local date `days` days before today."""
    if isinstance(field, models.DateTimeField):
        return now - timedelta(days=days)
    return timezone.localdate(now) - timedelta(days=days)


def purge_expired(now: datetime | None = None) -> dict[str, int]:
    """Apply every registered rule. Returns the rows deleted per rule (cascades included)."""
    now = now or timezone.now()
    return {rule.label: rule.purge(now) for rule in RULES}
