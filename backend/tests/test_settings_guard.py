"""The test suite refuses to create a test database on a Supabase (production) server.

Two layers call the same helper: config.settings_test at import, and tests/conftest.py's
pytest_sessionstart (which also runs when DJANGO_SETTINGS_MODULE is overridden)."""

import pytest
from django.core.exceptions import ImproperlyConfigured

from config.test_db_guard import REMOTE_TEST_DB_OVERRIDE, refuse_remote_test_database, refuse_remote_test_host


@pytest.mark.parametrize(
    "url",
    [
        "postgresql://postgres:pw@db.bkjepupqdwkraajyewyy.supabase.co:5432/postgres?sslmode=require",
        "postgresql://postgres.bkjepupqdwkraajyewyy:pw@aws-0-us-east-1.pooler.supabase.com:6543/postgres",
        "postgres://u:p@AWS-0-US-EAST-1.POOLER.SUPABASE.COM:5432/postgres",
    ],
)
def test_supabase_hosts_are_refused(url):
    with pytest.raises(ImproperlyConfigured, match="Supabase"):
        refuse_remote_test_database(url, environ={})


@pytest.mark.parametrize(
    "url",
    [
        "postgresql://plandit:pw@127.0.0.1:5433/plandit",
        "postgresql://plandit:pw@localhost/plandit",
        "postgresql://plandit:pw@postgres:5432/plandit",
        "postgresql://plandit:pw@db.internal.example.com/plandit",
    ],
)
def test_local_and_other_hosts_are_allowed(url):
    refuse_remote_test_database(url, environ={})


def test_override_allows_supabase_on_purpose():
    url = "postgresql://postgres:pw@db.project.supabase.co:5432/postgres"
    refuse_remote_test_database(url, environ={REMOTE_TEST_DB_OVERRIDE: "1"})
    with pytest.raises(ImproperlyConfigured):
        refuse_remote_test_database(url, environ={REMOTE_TEST_DB_OVERRIDE: "0"})


def test_supabase_in_the_password_or_path_is_not_a_host_match():
    refuse_remote_test_database("postgresql://plandit:supabase@127.0.0.1:5433/supabase", environ={})


@pytest.mark.parametrize("host", ["db.ref.supabase.co", "AWS-0-US-EAST-1.POOLER.SUPABASE.COM"])
def test_host_check_used_by_conftest_refuses_supabase(host):
    with pytest.raises(ImproperlyConfigured):
        refuse_remote_test_host(host, environ={})


@pytest.mark.parametrize("host", ["127.0.0.1", "localhost", "", None])
def test_host_check_used_by_conftest_allows_local(host):
    refuse_remote_test_host(host, environ={})
