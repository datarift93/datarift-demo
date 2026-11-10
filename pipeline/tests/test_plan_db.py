"""F6 acceptance: plan_vs_actual matches control SQL on the raw tables.

Imports the full default dataset into a fresh org (the import refreshes the analytics
views), then compares `plan_vs_actual`, called as a signed-in member the way the app calls
it, with budgets and order lines summed directly, at store, region and network level.
Also checks the planted signals from `_truth.json`: weak stores clearly miss the plan.
Needs a migrated local Supabase (skipped otherwise, unless REQUIRE_DB=1).
"""

import os
import uuid
from decimal import Decimal

import psycopg
import pytest
from conftest import CONFIG_PATH, RATES_PATH, Dataset

from datarift_pipeline import importer
from datarift_pipeline.config import load_config

URL = os.environ.get("DATABASE_URL", importer.LOCAL_DATABASE_URL)


def _db_available() -> bool:
    try:
        with psycopg.connect(URL, connect_timeout=2) as conn:
            return conn.execute(
                "select to_regproc('public.plan_vs_actual') is not null"
            ).fetchone()[0]
    except psycopg.OperationalError:
        return False


if not _db_available():
    if os.environ.get("REQUIRE_DB") == "1":
        raise RuntimeError(f"REQUIRE_DB=1 but no migrated database at {URL}")
    pytest.skip("no local Supabase database with the plan migration", allow_module_level=True)


@pytest.fixture(scope="module")
def member(default_dataset: Dataset):
    """A fresh org with the full dataset and a demo member; removed afterwards."""
    slug = f"pytest-plan-{uuid.uuid4().hex[:8]}"
    user_id = uuid.uuid4()
    with psycopg.connect(URL, autocommit=True) as conn:
        org_id = conn.execute(
            "insert into public.orgs (slug, name) values (%s, 'pytest plan') returning id", (slug,)
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


# Store x month on the raw tables: budgets full-joined with order lines by local month,
# restricted to the full months of [from, to] and to stores matching the filters.
CONTROL_BASE = """
    with months as (
      select m::date as month
      from generate_series(date_trunc('month', %(from)s::date - 1) + interval '1 month',
                           date_trunc('month', %(to)s::date + 1) - interval '1 month',
                           interval '1 month') as m
    ),
    stores as (
      select s.id, s.store_code, r.region_code, coalesce(r.name, 'Sklep internetowy') as region
      from public.stores s left join public.regions r on r.id = s.region_id
      where s.org_id = %(org)s
        and (%(channel)s::public.sales_channel is null
             or s.channel = %(channel)s::public.sales_channel)
        and (%(region)s::text is null or r.region_code = %(region)s::text)
    ),
    actual as (
      select o.store_id,
             date_trunc('month', (o.ordered_at at time zone 'Europe/Warsaw'))::date as month,
             sum(l.line_revenue) as revenue
      from public.orders o join public.order_lines l on l.order_id = o.id
      where o.org_id = %(org)s
      group by 1, 2
    ),
    base as (
      select st.store_code, st.region, m.month,
             coalesce(b.revenue_plan, 0) as plan, coalesce(a.revenue, 0) as actual
      from stores st cross join months m
      left join public.budgets b on b.store_id = st.id and b.month = m.month
      left join actual a on a.store_id = st.id and a.month = m.month
      where b.id is not null or a.revenue is not null
    )
"""

CONTROL = {
    "store": CONTROL_BASE
    + "select store_code, region, month, sum(plan), sum(actual) from base group by 1, 2, 3",
    "region": CONTROL_BASE
    + "select null::text, region, month, sum(plan), sum(actual) from base group by 2, 3",
    "network": CONTROL_BASE
    + "select null::text, null::text, month, sum(plan), sum(actual) from base group by 3",
}

FUNCTION = """
    select store_code, case when level = 'network' then null else region_name end,
           month, plan, actual, realization, deviation
    from public.plan_vs_actual(%(org)s, %(from)s, %(to)s, %(channel)s, %(region)s, %(category)s)
    where level = %(level)s and month is not null
"""

CASES = [
    # (from, to, channel, region, category)
    ("2024-01-01", "2025-12-31", None, None, None),  # everything
    ("2025-10-01", "2025-12-31", "online", None, "HOME"),  # category is ignored
    ("2025-10-15", "2025-12-31", "store", "14", None),  # partial October is dropped
    ("2024-02-01", "2024-02-29", None, None, None),  # one month, leap year
    ("2025-03-01", "2025-06-30", "store", "12", "SPORT"),
]


@pytest.mark.parametrize("level", ["store", "region", "network"])
@pytest.mark.parametrize(("start", "end", "channel", "region", "category"), CASES)
def test_matches_control_query(member, level, start, end, channel, region, category):
    org_id, user_id = member
    params = {
        "org": org_id,
        "from": start,
        "to": end,
        "channel": channel,
        "region": region,
        "category": category,
        "level": level,
    }
    with psycopg.connect(URL) as conn:
        expected = {r[:3]: r[3:] for r in conn.execute(CONTROL[level], params).fetchall()}
        assert expected, "case must hit data"
        _as_member(conn, user_id)
        rows = conn.execute(FUNCTION, params).fetchall()
    got = {r[:3]: r[3:5] for r in rows}
    assert got == expected
    for _, _, _, plan, actual, realization, deviation in rows:
        assert deviation == actual - plan
        if plan == 0:
            assert realization is None
        else:  # Postgres numeric division rounds at ~20 digits, Python's Decimal at 28
            assert abs(realization - actual / plan) < Decimal("1e-15")


def test_period_totals_add_up(member):
    """Rows with month null are the sum of the monthly rows at every level."""
    org_id, user_id = member
    with psycopg.connect(URL) as conn:
        _as_member(conn, user_id)
        rows = conn.execute(
            "select level, store_code, region_name, month, plan, actual"
            " from public.plan_vs_actual(%s, '2024-01-01', '2025-12-31')",
            (org_id,),
        ).fetchall()
    totals: dict[tuple, list[Decimal]] = {}
    monthly: dict[tuple, list[Decimal]] = {}
    for level, store, region, month, plan, actual in rows:
        target = totals if month is None else monthly
        acc = target.setdefault((level, store, region), [Decimal(0), Decimal(0)])
        acc[0] += plan
        acc[1] += actual
    assert totals == monthly
    assert {k[0] for k in totals} == {"store", "region", "network"}


def test_every_store_has_a_budget_for_every_full_month(member, default_dataset: Dataset):
    org_id, user_id = member
    with psycopg.connect(URL) as conn:
        months, missing = conn.execute(
            """with months as (
                 select generate_series(date_trunc('month', min(d)), date_trunc('month', max(d)),
                                        interval '1 month')::date as month
                 from (select (ordered_at at time zone 'Europe/Warsaw')::date as d
                       from public.orders where org_id = %(org)s) o
               )
               select (select count(*) from months),
                      (select count(*) from public.stores s cross join months m
                       where s.org_id = %(org)s and not exists (
                         select 1 from public.budgets b
                         where b.store_id = s.id and b.month = m.month and b.revenue_plan > 0))""",
            {"org": org_id},
        ).fetchone()
        stores = conn.execute(
            "select count(*) from public.stores where org_id = %s", (org_id,)
        ).fetchone()[0]
        _as_member(conn, user_id)
        no_plan = conn.execute(
            """select count(*), count(*) filter (where plan = 0)
               from public.plan_vs_actual(%s, '2024-01-01', '2025-12-31')
               where level = 'store' and month is not null""",
            (org_id,),
        ).fetchone()
    assert months == 24
    assert missing == 0
    assert no_plan == (stores * months, 0)
    assert stores == len(default_dataset.rows["stores.csv"])


def test_weak_stores_miss_the_plan(member, default_dataset: Dataset):
    org_id, user_id = member
    weak = {s["store_code"] for s in default_dataset.truth["weak_stores"]}
    declining = {s["store_code"] for s in default_dataset.truth["declining_stores"]}
    assert weak == {"KAT-01", "WAW-02", "OLS-01"}
    with psycopg.connect(URL) as conn:
        _as_member(conn, user_id)
        realization = dict(
            conn.execute(
                """select store_code, realization
                   from public.plan_vs_actual(%s, '2024-01-01', '2025-12-31')
                   where level = 'store' and month is null""",
                (org_id,),
            ).fetchall()
        )
    for code in weak:
        assert realization[code] < Decimal("0.9"), code
    for code in set(realization) - weak - declining:
        assert Decimal("0.9") <= realization[code] <= Decimal("1.05"), code
    # The weak stores stand out: each is below every regular store.
    regular = [realization[c] for c in set(realization) - weak - declining]
    assert max(realization[c] for c in weak) < min(regular)
