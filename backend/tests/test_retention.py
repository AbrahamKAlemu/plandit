"""The expiry registry (group plans, slice G0; brief GS-5). Later slices register their tables;
until then nothing is deleted."""

import uuid
from datetime import UTC, date, datetime, timedelta
from io import StringIO

import pytest
from django.core.exceptions import FieldDoesNotExist
from django.core.management import call_command
from django.db import models

from plandit.core import retention
from plandit.core.models import Profile
from plandit.shares.models import SharedPlan


class FakeRule:
    label = "fake.Answer.created_at"

    def __init__(self, deletes=0):
        self.deletes = deletes
        self.calls = []

    def purge(self, now):
        self.calls.append(now)
        return self.deletes


def test_purge_expired_runs_every_registered_rule(monkeypatch):
    first, second = FakeRule(deletes=2), FakeRule(deletes=0)
    second.label = "fake.Request.day"
    monkeypatch.setattr(retention, "RULES", [first, second])
    now = datetime(2026, 12, 1, 12, tzinfo=UTC)

    assert retention.purge_expired(now) == {"fake.Answer.created_at": 2, "fake.Request.day": 0}
    assert first.calls == [now] and second.calls == [now]


def test_purge_expired_defaults_to_now(monkeypatch):
    rule = FakeRule()
    monkeypatch.setattr(retention, "RULES", [rule])
    before = datetime.now(UTC)
    retention.purge_expired()
    assert before <= rule.calls[0] <= datetime.now(UTC)


def test_with_no_rules_nothing_is_deleted(monkeypatch):
    monkeypatch.setattr(retention, "RULES", [])
    assert retention.purge_expired() == {}


def test_register_adds_a_rule_and_checks_the_field(monkeypatch):
    monkeypatch.setattr(retention, "RULES", [])
    rule = retention.register(SharedPlan, "created_at", days=30)
    assert retention.RULES == [rule]
    assert rule.label == "shares.SharedPlan.created_at"
    with pytest.raises(FieldDoesNotExist):
        retention.register(SharedPlan, "no_such_field", days=30)
    with pytest.raises(ValueError):
        retention.register(SharedPlan, "created_at", days=0)


def test_the_cutoff_is_a_moment_for_datetimes_and_a_local_day_for_dates():
    now = datetime(2026, 12, 31, 3, 0, tzinfo=UTC)  # still December 30 in New York
    assert retention.cutoff(models.DateTimeField(), now, 30) == now - timedelta(days=30)
    assert retention.cutoff(models.DateField(), now, 30) == date(2026, 11, 30)


@pytest.mark.django_db
def test_a_rule_deletes_rows_at_or_past_the_limit_and_nothing_newer(monkeypatch):
    owner = Profile.objects.create(id=uuid.uuid4(), email="o@columbia.edu", name="Organizer")
    now = datetime(2026, 12, 31, 12, tzinfo=UTC)
    ages = {"old": 31, "boundary": 30, "new": 29}
    for name, days in ages.items():
        shared = SharedPlan.objects.create(owner=owner, plan_id=uuid.uuid4(), data={"title": name})
        SharedPlan.objects.filter(pk=shared.pk).update(created_at=now - timedelta(days=days))
    monkeypatch.setattr(retention, "RULES", [])
    retention.register(SharedPlan, "created_at", days=30)

    assert retention.purge_expired(now) == {"shares.SharedPlan.created_at": 2}
    assert [shared.data["title"] for shared in SharedPlan.objects.all()] == ["new"]


def test_the_command_reports_what_it_purged(monkeypatch):
    monkeypatch.setattr(retention, "RULES", [FakeRule(deletes=3)])
    out = StringIO()
    call_command("purge_expired", stdout=out)
    assert "fake.Answer.created_at: 3 deleted" in out.getvalue()


def test_the_command_says_when_there_is_nothing_to_purge(monkeypatch):
    monkeypatch.setattr(retention, "RULES", [])
    out = StringIO()
    call_command("purge_expired", stdout=out)
    assert "No expiry rules registered" in out.getvalue()
