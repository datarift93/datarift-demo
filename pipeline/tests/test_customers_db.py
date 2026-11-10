"""F3 acceptance: customer functions match control SQL on the raw tables, and the churn
planted by the generator is visible.

Imports the full default dataset into a fresh org, refreshes `analytics.customer_day`
explicitly (Stage 6 sessions each redefine `private.refresh_analytics()` until they are
merged, so the import trigger may not include it), then compares `customer_rfm_segments`
and `customer_cohorts`, called as a signed-in member, with queries on `orders` /
`order_lines` / `customers`. Needs a migrated local Supabase (skipped otherwise, unless
REQUIRE_DB=1).
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

SEGMENTS = ["Mistrzowie", "Lojalni", "Nowi", "Obiecujący", "Zagrożeni odejściem", "Utraceni"]


def _db_available() -> bool:
    try:
        with psycopg.connect(URL, connect_timeout=2) as conn:
            return conn.execute(
                "select to_regproc('public.customer_rfm_segments') is not null"
            ).fetchone()[0]
    except psycopg.OperationalError:
        return False


if not _db_available():
    if os.environ.get("REQUIRE_DB") == "1":
        raise RuntimeError(f"REQUIRE_DB=1 but no migrated database at {URL}")
    pytest.skip("no local Supabase database with the customers migration", allow_module_level=True)


@pytest.fixture(scope="module")
def member(default_dataset: Dataset):
    """A fresh org with the full dataset and a demo member; removed afterwards."""
    slug = f"pytest-customers-{uuid.uuid4().hex[:8]}"
    user_id = uuid.uuid4()
    with psycopg.connect(URL, autocommit=True) as conn:
        org_id = conn.execute(
            "insert into public.orgs (slug, name) values (%s, 'pytest customers') returning id",
            (slug,),
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
    with psycopg.connect(URL, autocommit=True) as conn:
        conn.execute("refresh materialized view concurrently analytics.customer_day")
    yield org_id, user_id
    with psycopg.connect(URL, autocommit=True) as conn:
        conn.execute("delete from public.orgs where id = %s", (org_id,))
        conn.execute("delete from auth.users where id = %s", (user_id,))
        conn.execute("select private.refresh_analytics()")
        conn.execute("refresh materialized view concurrently analytics.customer_day")


def _as_member(conn: psycopg.Connection, user_id) -> None:
    conn.execute(
        "select set_config('request.jwt.claims', %s, true)",
        (f'{{"sub":"{user_id}","role":"authenticated"}}',),
    )
    conn.execute("set local role authenticated")


# Orders of identified customers matching the filters, by Warsaw day, straight from the
# model tables (no analytics view). Category is deliberately not a parameter: F3 ignores it.
CUSTOMER_ORDERS = """
    select o.customer_id, c.customer_code, o.id as order_id,
           (o.ordered_at at time zone 'Europe/Warsaw')::date as day, rev.revenue
    from public.orders o
    join (select l.order_id, sum(l.line_revenue) as revenue from public.order_lines l
          where l.org_id = %(org)s group by l.order_id) rev on rev.order_id = o.id
    join public.customers c on c.id = o.customer_id
    join public.stores s on s.id = o.store_id
    left join public.regions r on r.id = c.region_id
    where o.org_id = %(org)s and o.customer_id is not null
      and (%(channel)s::public.sales_channel is null
           or s.channel = %(channel)s::public.sales_channel)
      and (%(region)s::text is null or r.region_code = %(region)s::text)
"""

CONTROL_SEGMENTS = f"""
    with co as ({CUSTOMER_ORDERS}),
    per_customer as (
      select customer_id, customer_code,
             %(to)s::date - max(day) as recency,
             count(*) as total,
             count(*) filter (where day between %(to)s::date - 364 and %(to)s::date) as f,
             coalesce(sum(revenue) filter (
               where day between %(to)s::date - 364 and %(to)s::date), 0) as m
      from co where day <= %(to)s::date
      group by customer_id, customer_code
    ),
    scored as (
      select *, ntile(5) over (order by recency desc, customer_code) as r_s,
                ntile(5) over (order by f, customer_code) as f_s
      from per_customer
    ),
    labelled as (
      select *, case
        when r_s >= 4 and f_s >= 4 then 'Mistrzowie'
        when f_s >= 4 then 'Lojalni'
        when r_s >= 4 and total = 1 then 'Nowi'
        when r_s >= 3 then 'Obiecujący'
        when r_s = 2 then 'Zagrożeni odejściem'
        else 'Utraceni' end as segment
      from scored
    )
    select segment, count(*), sum(m) from labelled group by segment
"""

CONTROL_COHORTS = f"""
    with co as ({CUSTOMER_ORDERS}),
    firsts as (select customer_id, min(day) as first_day from co group by customer_id),
    members as (
      select customer_id, date_trunc('month', first_day)::date as cohort
      from firsts where first_day between %(from)s and %(to)s
    ),
    last_month as (
      select date_trunc('month', max(day) + 1)::date - interval '1 month' as m
      from (select (ordered_at at time zone 'Europe/Warsaw')::date as day
            from public.orders where org_id = %(org)s and customer_id is not null) d
    )
    select m.cohort,
           (extract(year from age(date_trunc('month', co.day), m.cohort)) * 12
             + extract(month from age(date_trunc('month', co.day), m.cohort)))::int as k,
           count(distinct m.customer_id)
    from members m join co using (customer_id), last_month lm
    where date_trunc('month', co.day) <= lm.m
    group by 1, 2
"""

SEGMENT_CASES = [
    # (from, to, channel, region)
    ("2024-01-01", "2025-12-31", None, None),  # everything
    ("2025-10-01", "2025-12-31", "online", None),
    ("2025-01-01", "2025-06-30", "store", "14"),
    ("2024-07-01", "2024-12-31", None, "12"),
]


def _params(org_id, start, end, channel, region) -> dict:
    return {"org": org_id, "from": start, "to": end, "channel": channel, "region": region}


def _call(conn, user_id, fn: str, params: dict) -> list[tuple]:
    _as_member(conn, user_id)
    rows = conn.execute(
        f"select * from public.{fn}(%(org)s, %(from)s, %(to)s, %(channel)s, %(region)s)", params
    ).fetchall()
    conn.execute("reset role")
    return rows


@pytest.mark.parametrize(("start", "end", "channel", "region"), SEGMENT_CASES)
def test_segments_match_control_query(member, start, end, channel, region):
    org_id, user_id = member
    params = _params(org_id, start, end, channel, region)
    with psycopg.connect(URL) as conn:
        expected = {seg: (n, m) for seg, n, m in conn.execute(CONTROL_SEGMENTS, params)}
        buyers = conn.execute(
            f"select count(distinct customer_id) from ({CUSTOMER_ORDERS}) co "
            "where day <= %(to)s::date",
            params,
        ).fetchone()[0]
        got = _call(conn, user_id, "customer_rfm_segments", params)
    assert buyers > 0, "case must hit data"
    assert [r[0] for r in got] == SEGMENTS, "always six segments in rule order"
    # Every customer with a purchase has exactly one segment.
    assert sum(r[1] for r in got) == buyers
    for segment, customers, revenue, *_ in got:
        assert (customers, revenue) == expected.get(segment, (0, Decimal(0))), segment
    assert sum(r[5] for r in got) == pytest.approx(1)
    assert sum(r[6] for r in got) == pytest.approx(1)


def test_lost_segment_not_empty_for_full_period(member):
    org_id, user_id = member
    with psycopg.connect(URL) as conn:
        rows = _call(
            conn,
            user_id,
            "customer_rfm_segments",
            _params(org_id, "2024-01-01", "2025-12-31", None, None),
        )
    got = {r[0]: r[1] for r in rows}
    assert got["Utraceni"] > 0
    assert got["Nowi"] > 0, "first-time buyers exist (the spec's literal rule made this empty)"
    assert all(got[s] > 0 for s in SEGMENTS), got


@pytest.mark.parametrize(
    ("start", "end", "channel", "region"),
    [
        ("2024-01-01", "2025-12-31", None, None),
        ("2024-03-15", "2025-02-28", "online", None),
        ("2024-01-01", "2025-12-31", "store", "24"),
    ],
)
def test_cohorts_match_control_query(member, start, end, channel, region):
    org_id, user_id = member
    params = _params(org_id, start, end, channel, region)
    with psycopg.connect(URL) as conn:
        expected = {(c, k): n for c, k, n in conn.execute(CONTROL_COHORTS, params)}
        got = _call(conn, user_id, "customer_cohorts", params)
    assert got, "case must hit data"
    for cohort, k, size, active, retention in got:
        assert active == expected.get((cohort, k), 0), (cohort, k)
        assert size == expected[(cohort, 0)]
        assert float(retention) == pytest.approx(active / size, abs=1e-15)
    # Every (cohort, month) the control query sees is in the function's grid.
    assert set(expected) <= {(r[0], r[1]) for r in got}


def _full_cohorts(member) -> list[tuple]:
    org_id, user_id = member
    with psycopg.connect(URL) as conn:
        return _call(
            conn,
            user_id,
            "customer_cohorts",
            _params(org_id, "2024-01-01", "2025-12-31", None, None),
        )


def test_month_zero_is_100_percent(member):
    rows = _full_cohorts(member)
    assert len({r[0] for r in rows}) == 24, "one cohort per month of the dataset"
    assert all(r[4] == 1 for r in rows if r[1] == 0)


def test_retention_declines_with_months(member):
    rows = _full_cohorts(member)

    def mean_at(k: int) -> float:
        values = [float(r[4]) for r in rows if r[1] == k]
        return sum(values) / len(values)

    curve = [mean_at(k) for k in (1, 3, 6, 12, 18)]
    assert curve == sorted(curve, reverse=True), curve
    assert curve[-1] < curve[0] * 0.75, curve


def test_promo_cohorts_retain_less_after_six_months(member, default_dataset: Dataset):
    """`_truth.json` churn rule: customers who registered (= first order) during a
    whole-assortment promotion have a much shorter mean lifetime."""
    org_id, user_id = member
    assert "whole-assortment promotion" in default_dataset.truth["churn"]["promo_cohort_rule"]
    with psycopg.connect(URL) as conn:
        promo_months = {
            m
            for (m,) in conn.execute(
                """select distinct date_trunc('month', d)::date
                   from public.promotions p,
                        generate_series(p.starts_on, p.ends_on, interval '1 day') d
                   where p.org_id = %s and p.category_id is null and p.product_id is null""",
                (org_id,),
            )
        }
    at6 = {r[0]: float(r[4]) for r in _full_cohorts(member) if r[1] == 6}
    promo = [v for m, v in at6.items() if m in promo_months]
    other = [v for m, v in at6.items() if m not in promo_months]
    assert len(promo) >= 3 and other
    assert max(promo) < sum(other) / len(other), (promo, other)
