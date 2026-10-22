"""
Enable row level security on every Plandit table.

Django connects as the role that owns these tables, and table owners bypass RLS, so Django
is unaffected. Supabase's auto-generated Data API (PostgREST) connects as `anon` /
`authenticated`, which now get no rows at all. Ownership is enforced in Django views.
"""

from django.db import migrations

TABLES = [
    "core_profile",
    "places_place",
    "saved_savedpost",
    "plans_dayplan",
    "plans_planstop",
    "plans_travelleg",
    "waitlist_waitlistsignup",
]


class Migration(migrations.Migration):
    dependencies = [
        ("core", "0001_initial"),
        ("places", "0001_initial"),
        ("saved", "0001_initial"),
        ("plans", "0001_initial"),
        ("waitlist", "0001_initial"),
    ]

    operations = [
        migrations.RunSQL(
            sql=[f"ALTER TABLE {table} ENABLE ROW LEVEL SECURITY;" for table in TABLES],
            reverse_sql=[f"ALTER TABLE {table} DISABLE ROW LEVEL SECURITY;" for table in TABLES],
        )
    ]
