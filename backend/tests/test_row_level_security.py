"""Every table in the public schema must have row level security on.

Supabase's Data API reaches the public schema as `anon` and `authenticated`, which Supabase grants
full rights on new tables. RLS with no policies is what keeps those roles out (see
core/migrations/0002). A new model needs a migration like core/0008, or this test fails.
"""

import pytest
from django.db import connection


@pytest.mark.django_db
def test_every_public_table_has_row_level_security():
    with connection.cursor() as cursor:
        cursor.execute(
            """
            select c.relname
            from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity
            order by c.relname
            """
        )
        missing = [row[0] for row in cursor.fetchall()]
    assert missing == []
