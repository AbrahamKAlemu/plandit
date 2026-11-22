"""Every table in the public schema must have row level security on.

Supabase's Data API reaches the public schema as `anon` and `authenticated`, which Supabase grants
full rights on new tables. RLS with no policies is what keeps those roles out (see
core/migrations/0002). A new model needs a migration like core/0008, or this test fails.
"""

import pytest
from django.db import connection

pytestmark = pytest.mark.django_db


def public_relations(where: str) -> list[str]:
    with connection.cursor() as cursor:
        cursor.execute(
            f"""
            select c.relname
            from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and {where}
            order by c.relname
            """
        )
        return [row[0] for row in cursor.fetchall()]


def test_every_public_table_has_row_level_security():
    assert public_relations("c.relkind in ('r', 'p') and not c.relrowsecurity") == []


def test_no_views_or_foreign_tables_in_public():
    # The Data API exposes these too, and they can't have RLS: a view reads its tables as its owner,
    # which bypasses theirs. Put one in another schema, or make it a view with security_invoker.
    assert public_relations("c.relkind in ('v', 'm', 'f')") == []
