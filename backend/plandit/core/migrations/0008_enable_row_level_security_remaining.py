"""
Enable row level security on every table that still had it off, same pattern as 0002, 0005 and
0007: the shared plan pages, resolution attempts, and the tables Django's own apps create.

Supabase grants `anon` and `authenticated` full rights on every table in the public schema, and
its Data API (PostgREST) connects as those roles with the app's public key. Without RLS, anyone
holding that key could read and change these tables, including inserting a Django admin user.
With RLS on and no policies, those roles get no rows. Django connects as the role that owns the
tables, and owners bypass RLS, so Django is unaffected.
"""

from django.db import migrations

TABLES = [
    "shares_sharedplan",
    "resolution_resolutionattempt",
    "auth_group",
    "auth_group_permissions",
    "auth_permission",
    "auth_user",
    "auth_user_groups",
    "auth_user_user_permissions",
    "django_admin_log",
    "django_content_type",
    "django_migrations",
    "django_session",
]


class Migration(migrations.Migration):
    dependencies = [
        ("core", "0007_enable_row_level_security_deleted_account"),
        ("shares", "0001_initial"),
        ("resolution", "0003_social_evidence_throttle_state"),
        ("auth", "0012_alter_user_first_name_max_length"),
        ("contenttypes", "0002_remove_content_type_name"),
        ("sessions", "0001_initial"),
        ("admin", "0003_logentry_add_action_flag_choices"),
    ]

    operations = [
        migrations.RunSQL(
            sql=[f"ALTER TABLE {table} ENABLE ROW LEVEL SECURITY;" for table in TABLES],
            reverse_sql=[f"ALTER TABLE {table} DISABLE ROW LEVEL SECURITY;" for table in TABLES],
        )
    ]
