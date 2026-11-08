"""End-to-end import of the full default dataset into a real database.

Needs a running local Supabase with the migrations applied (`supabase start` /
`supabase db start`). Skipped when no database is reachable, unless REQUIRE_DB=1
(set in the CI database job, so it can never silently skip there).
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
            return conn.execute(
                "select to_regproc('private.process_import') is not null"
            ).fetchone()[0]
    except psycopg.OperationalError:
        return False


if not _db_available():
    if os.environ.get("REQUIRE_DB") == "1":
        raise RuntimeError(f"REQUIRE_DB=1 but no migrated database at {URL}")
    pytest.skip("no local Supabase database with the import migration", allow_module_level=True)


@pytest.fixture(scope="module")
def org(default_dataset: Dataset):
    """A fresh org per test module, deleted (with all its data) afterwards."""
    slug = f"pytest-{uuid.uuid4().hex[:8]}"
    with psycopg.connect(URL, autocommit=True) as conn:
        org_id = conn.execute(
            "insert into public.orgs (slug, name) values (%s, 'pytest import') returning id",
            (slug,),
        ).fetchone()[0]
    yield slug, org_id
    with psycopg.connect(URL, autocommit=True) as conn:
        conn.execute("delete from public.orgs where id = %s", (org_id,))


def _import(dataset: Dataset, slug: str) -> importer.ImportResult:
    config = load_config(CONFIG_PATH)
    return importer.run_import(
        dataset.path, RATES_PATH, slug, config.start_date, config.end_date, "pytest", URL
    )


def _model_fingerprint(conn: psycopg.Connection, org_id) -> dict[str, tuple[int, int]]:
    """Row count and a content hash per model table: equal fingerprints = nothing changed."""
    tables = ("regions", "stores", "categories", "products", "customers", "promotions",
              "purchases", "orders", "order_lines", "budgets")  # fmt: skip
    out = {}
    for t in tables:
        out[t] = conn.execute(
            f"select count(*), coalesce(sum(hashtext(x::text)), 0) from public.{t} x "  # noqa: S608
            "where org_id = %s",
            (org_id,),
        ).fetchone()
    return out


def test_full_import_rejects_exactly_the_planted_rows(default_dataset: Dataset, org):
    slug, org_id = org
    result = _import(default_dataset, slug)
    dirty = default_dataset.truth["dirty_rows"]

    assert result.status == "partial"
    assert result.rows_rejected == len(dirty)

    with psycopg.connect(URL) as conn:
        rejected = set(
            conn.execute(
                "select distinct file, row_no from public.import_errors where import_run_id = %s",
                (result.run_id,),
            ).fetchall()
        )
        assert rejected == {(d["file"], d["row_no"]) for d in dirty}

        # Every clean row is in the model.
        for name, table in (("orders.csv", "orders"), ("order_lines.csv", "order_lines"),
                            ("purchases.csv", "purchases"), ("customers.csv", "customers"),
                            ("budgets.csv", "budgets")):  # fmt: skip
            count = conn.execute(
                f"select count(*) from public.{table} where org_id = %s",  # noqa: S608
                (org_id,),
            ).fetchone()[0]
            assert count == len(default_dataset.clean(name)), table

        # Every line has a cost (purchases cover the 90 days before every sale) and margins
        # are in a plausible retail range.
        lines, costed, margin_pct = conn.execute(
            """select count(*), count(unit_cost_pln), sum(line_margin) / sum(line_revenue)
               from public.order_lines where org_id = %s""",
            (org_id,),
        ).fetchone()
        assert costed == lines
        assert 0.2 < margin_pct < 0.45

        # EUR purchases carry the NBP rate of their date or the last publication day before it.
        wrong_rates = conn.execute(
            """select count(*) from public.purchases p
               where p.org_id = %s and p.currency = 'EUR'
                 and p.fx_rate <> (select f.mid_rate from public.fx_rates f
                                   where f.rate_date <= p.purchase_date
                                   order by f.rate_date desc limit 1)""",
            (org_id,),
        ).fetchone()[0]
        assert wrong_rates == 0


def test_reimport_changes_nothing(default_dataset: Dataset, org):
    slug, org_id = org
    with psycopg.connect(URL) as conn:
        before = _model_fingerprint(conn, org_id)
    assert before["order_lines"][0] > 0, "runs after the full import test"

    result = _import(default_dataset, slug)

    assert result.status == "partial"
    assert result.rows_rejected == len(default_dataset.truth["dirty_rows"])
    with psycopg.connect(URL) as conn:
        assert _model_fingerprint(conn, org_id) == before


def test_missing_org_is_reported(default_dataset: Dataset):
    with pytest.raises(importer.ImportFailed, match="nie istnieje"):
        importer.run_import(
            default_dataset.path, RATES_PATH, "no-such-org", date(2024, 1, 1),
            date(2025, 12, 31), "pytest", URL,
        )  # fmt: skip
