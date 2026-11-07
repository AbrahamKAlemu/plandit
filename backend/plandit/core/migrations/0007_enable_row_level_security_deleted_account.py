"""
Enable row level security on the account tombstone table, same pattern as core.0002 and 0005.
"""

from django.db import migrations

TABLES = [
    "core_deletedaccount",
]


class Migration(migrations.Migration):
    dependencies = [
        ("core", "0006_deleted_account"),
    ]

    operations = [
        migrations.RunSQL(
            sql=[f"ALTER TABLE {table} ENABLE ROW LEVEL SECURITY;" for table in TABLES],
            reverse_sql=[f"ALTER TABLE {table} DISABLE ROW LEVEL SECURITY;" for table in TABLES],
        )
    ]
