"""F2 acceptance: product functions match control SQL and planted signals on the full data.

Imports the full default dataset into a fresh org, then compares `product_ranking` and
`product_abc_summary`, called as a signed-in member the way the app calls them, with
per-product sums over `orders` / `order_lines` (ABC classes recomputed in Python) for
several filter combinations. Also recomputes the margin of imported (EUR) products from
the CSV files and the NBP rates, independently of the import SQL, and checks the Pareto
signal from `_truth.json`. Needs a migrated local Supabase (skipped otherwise, unless
REQUIRE_DB=1).
"""

import bisect
import csv
import os
import uuid
from collections import defaultdict
from datetime import date, timedelta
from decimal import ROUND_HALF_UP, Decimal

import psycopg
import pytest
from conftest import CONFIG_PATH, RATES_PATH, Dataset

from datarift_pipeline import importer
from datarift_pipeline.config import load_config

URL = os.environ.get("DATABASE_URL", importer.LOCAL_DATABASE_URL)
CENT = Decimal("0.01")


def _db_available() -> bool:
    try:
        with psycopg.connect(URL, connect_timeout=2) as conn:
            return conn.execute(
                "select to_regproc('public.product_ranking') is not null"
            ).fetchone()[0]
    except psycopg.OperationalError:
        return False


if not _db_available():
    if os.environ.get("REQUIRE_DB") == "1":
        raise RuntimeError(f"REQUIRE_DB=1 but no migrated database at {URL}")
    pytest.skip("no local Supabase database with the products migration", allow_module_level=True)


@pytest.fixture(scope="module")
def member(default_dataset: Dataset):
    """A fresh org with the full dataset and a demo member; removed afterwards."""
    slug = f"pytest-products-{uuid.uuid4().hex[:8]}"
    user_id = uuid.uuid4()
    with psycopg.connect(URL, autocommit=True) as conn:
        org_id = conn.execute(
            "insert into public.orgs (slug, name) values (%s, 'pytest products') returning id",
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
        # The import trigger refreshes through private.refresh_analytics(); refresh this
        # view explicitly so the test does not depend on which version of it is installed.
        conn.execute("refresh materialized view concurrently analytics.sales_product_store_day")
    yield org_id, user_id
    with psycopg.connect(URL, autocommit=True) as conn:
        conn.execute("delete from public.orgs where id = %s", (org_id,))
        conn.execute("delete from auth.users where id = %s", (user_id,))
        conn.execute("refresh materialized view concurrently analytics.sales_product_store_day")


def _as_member(conn: psycopg.Connection, user_id) -> None:
    conn.execute(
        "select set_config('request.jwt.claims', %s, true)",
        (f'{{"sub":"{user_id}","role":"authenticated"}}',),
    )
    conn.execute("set local role authenticated")


CONTROL = """
    select p.sku, sum(l.line_revenue), sum(l.line_margin), sum(l.quantity),
           count(distinct o.id), p.purchase_currency::text, c.category_code
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
    group by p.sku, p.purchase_currency, c.category_code
"""

RANKING = """
    select rank, sku, revenue, margin, margin_pct, units, orders, revenue_share, cum_share,
           abc_class, purchase_currency::text, category_code
    from public.product_ranking(%(org)s, %(from)s, %(to)s, %(channel)s, %(region)s, %(category)s)
"""

CASES = [
    # (from, to, channel, region, category)
    ("2024-01-01", "2025-12-31", None, None, None),  # everything
    ("2025-10-01", "2025-12-31", "online", None, "HOME"),
    ("2025-10-01", "2025-12-31", "store", "14", None),
    ("2024-11-25", "2024-12-01", None, None, None),  # Black Friday week
    ("2025-03-01", "2025-03-31", "store", "12", "SPORT"),
    ("2025-12-31", "2025-12-31", "online", None, None),  # one day
]


def _params(org_id, start, end, channel=None, region=None, category=None) -> dict:
    return {
        "org": org_id,
        "from": start,
        "to": end,
        "channel": channel,
        "region": region,
        "category": category,
    }


def _abc(rows):
    """Control ranking: (sku, revenue, ...) rows -> rows in ABC order with share and class."""
    ordered = sorted(rows, key=lambda r: (-r[1], r[0]))
    total = sum(r[1] for r in ordered)
    out, cum = [], Decimal(0)
    for i, r in enumerate(ordered, start=1):
        before = cum / total
        cum += r[1]
        if i == 1 or before < Decimal("0.80"):
            cls = "A"
        elif before < Decimal("0.95"):
            cls = "B"
        else:
            cls = "C"
        out.append((i, *r, cum / total, cls))
    return out, total


@pytest.mark.parametrize(("start", "end", "channel", "region", "category"), CASES)
def test_ranking_matches_control_query(member, start, end, channel, region, category):
    org_id, user_id = member
    params = _params(org_id, start, end, channel, region, category)
    with psycopg.connect(URL) as conn:
        control = conn.execute(CONTROL, params).fetchall()
        assert control, "case must hit data"
        _as_member(conn, user_id)
        got = conn.execute(RANKING, params).fetchall()

    expected, total = _abc(control)
    assert len(got) == len(expected)
    for g, e in zip(got, expected, strict=True):
        rank, sku, revenue, margin, units, orders, currency, category_code, cum, cls = e
        assert (g[0], g[1], g[2], g[3], g[5], g[6]) == (rank, sku, revenue, margin, units, orders)
        assert (g[10], g[11]) == (currency, category_code)
        if revenue:
            assert abs(g[4] - margin / revenue) < Decimal("1e-15")
        else:
            assert g[4] is None
        assert abs(g[7] - revenue / total) < Decimal("1e-15")
        assert abs(g[8] - cum) < Decimal("1e-15")
        assert g[9] == cls, f"{sku}: class {g[9]}, expected {cls}"


@pytest.mark.parametrize(("start", "end", "channel", "region", "category"), CASES[:3])
def test_summary_matches_ranking_classes(member, start, end, channel, region, category):
    org_id, user_id = member
    params = _params(org_id, start, end, channel, region, category)
    with psycopg.connect(URL) as conn:
        expected, total = _abc(conn.execute(CONTROL, params).fetchall())
        _as_member(conn, user_id)
        got = conn.execute(
            """select abc_class, products, revenue, revenue_share, product_share
               from public.product_abc_summary(
                 %(org)s, %(from)s, %(to)s, %(channel)s, %(region)s, %(category)s)""",
            params,
        ).fetchall()

    assert [g[0] for g in got] == ["A", "B", "C"]
    for cls, products, revenue, revenue_share, product_share in got:
        mine = [e for e in expected if e[-1] == cls]
        assert products == len(mine)
        assert revenue == sum(e[2] for e in mine)
        assert abs(revenue_share - revenue / total) < Decimal("1e-15")
        assert abs(product_share - Decimal(len(mine)) / len(expected)) < Decimal("1e-15")
    assert abs(sum(g[3] for g in got) - 1) < Decimal("1e-15")
    assert abs(sum(g[4] for g in got) - 1) < Decimal("1e-15")


def test_full_period_abc_is_close_to_80_15_5(member):
    org_id, user_id = member
    with psycopg.connect(URL) as conn:
        _as_member(conn, user_id)
        shares = dict(
            conn.execute(
                """select abc_class, revenue_share
                   from public.product_abc_summary(%s, '2024-01-01', '2025-12-31')""",
                (org_id,),
            ).fetchall()
        )
    # The class takes the product that crosses the threshold, so A is a little over 80%.
    assert Decimal("0.80") <= shares["A"] < Decimal("0.83")
    assert Decimal("0.12") < shares["B"] <= Decimal("0.15")
    assert Decimal("0.02") < shares["C"] <= Decimal("0.05")


def test_pareto_top_20_percent_of_skus(member, default_dataset: Dataset):
    """Signal from _truth.json: Zipf popularity, top 20% of SKUs = 70-85% of revenue."""
    org_id, user_id = member
    with psycopg.connect(URL) as conn:
        _as_member(conn, user_id)
        cum = [
            r[0]
            for r in conn.execute(
                "select cum_share from public.product_ranking(%s, '2024-01-01', '2025-12-31')",
                (org_id,),
            ).fetchall()
        ]
    top = max(1, round(len(cum) * 0.2))
    share = cum[top - 1]
    assert Decimal("0.70") <= share <= Decimal("0.85")
    truth = default_dataset.truth["pareto"]["top_20pct_sku_revenue_share"]
    # The generator measures before the import rejects the deliberately broken rows.
    assert abs(float(share) - truth) < 0.01


# ---------------------------------------------------------------- EUR product margin


def _rates() -> tuple[list[date], list[Decimal]]:
    with RATES_PATH.open(encoding="utf-8", newline="") as fh:
        rows = sorted(
            (date.fromisoformat(r["rate_date"]), Decimal(r["mid_rate"])) for r in csv.DictReader(fh)
        )
    return [d for d, _ in rows], [r for _, r in rows]


def _nbp_rate(days: list[date], rates: list[Decimal], on: date) -> Decimal:
    """NBP mid rate of the day, or of the last publication day before it."""
    i = bisect.bisect_right(days, on) - 1
    assert i >= 0, f"no NBP rate on or before {on}"
    return rates[i]


def test_eur_product_margin_matches_manual_nbp_conversion(member, default_dataset: Dataset):
    """Margin of 3 imported products, recomputed from the CSVs and the NBP rates.

    unit_cost_pln of a line = weighted average over the product's purchases in the 90 days
    up to the order day (purchase_date in (day - 90, day]) of round(unit_cost * NBP rate, 2),
    the rate from the purchase day or the last publication day before it.
    """
    org_id, user_id = member
    days, rates = _rates()

    purchases = defaultdict(list)  # sku -> [(date, quantity, unit_cost_pln)]
    for r in default_dataset.clean("purchases.csv"):
        if r["currency"] != "EUR":
            continue
        d = date.fromisoformat(r["purchase_date"])
        pln = (Decimal(r["unit_cost"]) * _nbp_rate(days, rates, d)).quantize(CENT, ROUND_HALF_UP)
        purchases[r["sku"]].append((d, int(r["quantity"]), pln))

    with psycopg.connect(URL) as conn:
        _as_member(conn, user_id)
        ranking = conn.execute(
            """select sku, margin, purchase_currency::text
               from public.product_ranking(%s, '2024-01-01', '2025-12-31')""",
            (org_id,),
        ).fetchall()
        conn.execute("reset role")
        # Three EUR products from different parts of the ranking: first, middle, last.
        eur = [r for r in ranking if r[2] == "EUR"]
        picked = [eur[0], eur[len(eur) // 2], eur[-1]]
        for sku, margin, _ in picked:
            lines = conn.execute(
                """select (o.ordered_at at time zone 'Europe/Warsaw')::date,
                          l.quantity, l.unit_price, l.unit_cost_pln
                   from public.order_lines l
                   join public.orders o on o.id = l.order_id
                   join public.products p on p.id = l.product_id
                   where l.org_id = %s and p.sku = %s""",
                (org_id, sku),
            ).fetchall()
            assert lines
            manual = Decimal(0)
            for day, qty, price, db_cost in lines:
                window = [
                    (q, c) for d, q, c in purchases[sku] if day - timedelta(days=90) < d <= day
                ]
                assert window, f"{sku}: no purchase in the 90 days before {day}"
                cost = (sum(q * c for q, c in window) / sum(q for q, _ in window)).quantize(
                    CENT, ROUND_HALF_UP
                )
                assert db_cost == cost, f"{sku} on {day}: unit_cost_pln {db_cost} != {cost}"
                manual += qty * (price - cost)
            assert margin == manual, f"{sku}: margin {margin} != manual {manual}"
