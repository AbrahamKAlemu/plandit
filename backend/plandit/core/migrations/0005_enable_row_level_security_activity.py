"""
Enable row level security on the account snapshot and activity tables, same pattern as
core.0002: Django owns the tables and bypasses RLS; Supabase's Data API roles get no rows.
"""

from django.db import migrations

TABLES = [
    "core_appsnapshot",
    "core_activityday",
    "core_activityevent",
]


class Migration(migrations.Migration):
    dependencies = [
        ("core", "0004_backfill_signups"),
    ]

    operations = [
        migrations.RunSQL(
            sql=[f"ALTER TABLE {table} ENABLE ROW LEVEL SECURITY;" for table in TABLES],
            reverse_sql=[f"ALTER TABLE {table} DISABLE ROW LEVEL SECURITY;" for table in TABLES],
        )
    ]
