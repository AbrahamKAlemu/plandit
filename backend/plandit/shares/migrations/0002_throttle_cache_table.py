"""
The table behind the `throttle` cache alias (settings.CACHES), which counts requests to the public
forms (plandit.core.public_forms.rate_limited), with row level security on, same pattern as
core/0008: Supabase's Data API roles get no rows, and Django, which owns the table, is unaffected.

The table isn't a model. Django's own createcachetable makes it, so its columns are exactly the
ones DatabaseCache reads and writes; if the table already exists, that leaves it as it is.
"""

from django.core.management import call_command
from django.db import migrations

TABLE = "plandit_throttle_cache"


def create_cache_table(apps, schema_editor):
    call_command("createcachetable", TABLE, database=schema_editor.connection.alias, verbosity=0)


def drop_cache_table(apps, schema_editor):
    schema_editor.execute(f"DROP TABLE IF EXISTS {schema_editor.quote_name(TABLE)}")


class Migration(migrations.Migration):
    dependencies = [
        ("shares", "0001_initial"),
        ("core", "0008_enable_row_level_security_remaining"),
    ]

    operations = [
        migrations.RunPython(create_cache_table, drop_cache_table),
        migrations.RunSQL(
            sql=[f"ALTER TABLE {TABLE} ENABLE ROW LEVEL SECURITY;"],
            reverse_sql=[f"ALTER TABLE {TABLE} DISABLE ROW LEVEL SECURITY;"],
        ),
    ]
