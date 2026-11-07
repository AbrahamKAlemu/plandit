"""
Backfill the claim-derived account fields for profiles that existed before accounts shipped.

Rule from docs/features/accounts-and-metrics/01-design.md: a profile with no email was an
anonymous Supabase session (old TestFlight builds); any other profile signed up when its row
was created.
"""

from django.db import migrations
from django.db.models import F


def backfill(apps, schema_editor):
    Profile = apps.get_model("core", "Profile")
    Profile.objects.filter(email="").update(is_anonymous=True, signed_up_at=None)
    Profile.objects.exclude(email="").filter(signed_up_at__isnull=True).update(
        is_anonymous=False, signed_up_at=F("created_at")
    )


def noop(apps, schema_editor):
    pass


class Migration(migrations.Migration):
    dependencies = [
        ("core", "0003_accounts_and_activity"),
    ]

    operations = [
        migrations.RunPython(backfill, noop),
    ]
