"""F1 acceptance: KPI functions match a control SQL query on the raw order lines.

Imports the full default dataset into a fresh org (the import refreshes the analytics
views), then compares `kpi_summary` and `kpi_timeseries`, called as a signed-in member
the way the app calls them, with sums over `orders` / `order_lines` for several filter
combinations. Needs a migrated local Supabase (skipped otherwise, unless REQUIRE_DB=1).
"""

import os
import uuid
from datetime import date

import psycopg
import pytest
from conftest import CONFIG_PATH, RATES_PATH, Dataset

from datarift_pipeline import importer
from datarift_pipeline.config import load_config

URL = os.environ.get("DATABASE_URL", importer.LOCAL_DATABASE_URL)


def _db_available() -> bool:
    try:
        with psycopg.connect(URL, connect_timeout=2) as conn:
            return conn.execute("select to_regproc('public.kpi_summary') is not null").fetchone()[0]
    except psycopg.OperationalError:
        return False


if not _db_available():
    if os.environ.get("REQUIRE_DB") == "1":
        raise RuntimeError(f"REQUIRE_DB=1 but no migrated database at {URL}")
    pytest.skip("no local Supabase database with the KPI migration", allow_module_level=True)


@pytest.fixture(scope="module")
def member(default_dataset: Dataset):
    """A fresh org with the full dataset and a demo member; removed afterwards."""
    slug = f"pytest-kpi-{uuid.uuid4().hex[:8]}"
    user_id = uuid.uuid4()
    with psycopg.connect(URL, autocommit=True) as conn:
        org_id = conn.execute(
            "insert into public.orgs (slug, name) values (%s, 'pytest kpi') returning id", (slug,)
        ).fetchone()[0]
        conn.execute(
            "insert into auth.users (id, email) values (%s, %s)", (user_id, f"{slug}@test.local")
        )
        conn.execute(
            "insert into public.org_members (org_id, user_id, role) values (%s, %s, 'demo')",
            (org_id, user_id),
        )
    config = load_config(CONFIG_PATH)
    importer.run_import(
        default_dataset.path, RATES_PATH, slug, config.start_date, config.end_date, "pytest", URL
    )
    yield org_id, user_id
    with psycopg.connect(URL, autocommit=True) as conn:
        conn.execute("delete from public.orgs where id = %s", (org_id,))
        conn.execute("delete from auth.users where id = %s", (user_id,))
        conn.execute("select private.refresh_analytics()")


def _as_member(conn: psycopg.Connection, user_id) -> None:
    conn.execute(
        "select set_config('request.jwt.claims', %s, true)",
        (f'{{"sub":"{user_id}","role":"authenticated"}}',),
    )
    conn.execute("set local role authenticated")


CONTROL = """
    select coalesce(sum(l.line_revenue), 0), coalesce(sum(l.line_margin), 0),
           count(distinct o.id), coalesce(sum(l.quantity), 0)
    from public.orders o
    join public.order_lines l on l.order_id = o.id
    join public.products p on p.id = l.product_id
    join public.categories c on c.id = p.category_id
    join public.stores s on s.id = o.store_id
    left join public.regions r on r.id = s.region_id
    where o.org_id = %(org)s
      and (o.ordered_at at time zone 'Europe/Warsaw')::date between %(from)s and %(to)s
      and (%(channel)s::public.sales_channel is null
           or s.channel = %(channel)s::public.sales_channel)
      and (%(region)s::text is null or r.region_code = %(region)s::text)
      and (%(category)s::text is null or c.category_code = %(category)s::text)
"""

CASES = [
    # (from, to, channel, region, category)
    ("2024-01-01", "2025-12-31", None, None, None),  # everything
    ("2025-10-01", "2025-12-31", "online", None, "HOME"),  # the example from the requirements
    ("2025-10-01", "2025-12-31", "store", "14", None),
    ("2024-11-25", "2024-12-01", None, None, None),  # Black Friday week
    ("2025-03-01", "2025-03-31", "store", "12", "SPORT"),
    ("2025-12-31", "2025-12-31", "online", None, None),  # one day
]


@pytest.mark.parametrize(("start", "end", "channel", "region", "category"), CASES)
def test_summary_matches_control_query(member, start, end, channel, region, category):
    org_id, user_id = member
    params = {
        "org": org_id,
        "from": start,
        "to": end,
        "channel": channel,
        "region": region,
        "category": category,
    }
    with psycopg.connect(URL) as conn:
        expected = conn.execute(CONTROL, params).fetchone()
        assert expected[2] > 0, "case must hit data"
        _as_member(conn, user_id)
        got = conn.execute(
            """select revenue, margin, orders, units from public.kpi_summary(
                 %(org)s, %(from)s, %(to)s, %(channel)s, %(region)s, %(category)s)
               where period = 'current'""",
            params,
        ).fetchone()
    assert tuple(got) == tuple(expected)


def test_previous_period_matches_control_query(member):
    org_id, user_id = member
    with psycopg.connect(URL) as conn:
        # Q4 2025 (92 days) -> previous period 01.07-30.09.2025
        expected = conn.execute(
            CONTROL,
            {
                "org": org_id,
                "from": date(2025, 7, 1),
                "to": date(2025, 9, 30),
                "channel": None,
                "region": None,
                "category": None,
            },
        ).fetchone()
        _as_member(conn, user_id)
        got = conn.execute(
            """select date_from, date_to, revenue, orders
               from public.kpi_summary(%s, '2025-10-01', '2025-12-31')
               where period = 'previous'""",
            (org_id,),
        ).fetchone()
    assert got == (date(2025, 7, 1), date(2025, 9, 30), expected[0], expected[2])


@pytest.mark.parametrize(("start", "end", "grain"), [
    ("2025-12-01", "2025-12-31", "day"),
    ("2025-01-01", "2025-12-31", "week"),
    ("2024-01-01", "2025-12-31", "month"),
])  # fmt: skip
def test_timeseries_adds_up_to_summary(member, start, end, grain):
    org_id, user_id = member
    with psycopg.connect(URL) as conn:
        _as_member(conn, user_id)
        rows = conn.execute(
            "select grain, revenue from public.kpi_timeseries(%s, %s, %s, 'online')",
            (org_id, start, end),
        ).fetchall()
        total = conn.execute(
            "select revenue from public.kpi_summary(%s, %s, %s, 'online') where period = 'current'",
            (org_id, start, end),
        ).fetchone()[0]
    assert {g for g, _ in rows} == {grain}
    assert sum(r for _, r in rows) == total
