"""Import the generated CSV files into Supabase (docs/requirements.md 2.4).

This module only moves bytes: it creates an import run, COPYs every file into the
`staging` schema as text (tagged with the run id and row number) and calls
`private.process_import(run_id)`. Validation, the model upsert, NBP conversion and the
log all live in the database (supabase/migrations/*_import_pipeline.sql).

The connection string comes from `--database-url`, then `DATABASE_URL` (environment or
`pipeline/.env`, never committed), then the local Supabase default.
"""

import csv
import json
import os
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import date
from pathlib import Path

import psycopg
from psycopg import sql

LOCAL_DATABASE_URL = "postgresql://postgres:postgres@127.0.0.1:54322/postgres"


@dataclass(frozen=True)
class SourceFile:
    name: str
    table: str
    columns: tuple[str, ...]


# Dependency order does not matter here (the database processes files in its own order),
# but the column lists must match docs/data-model.md section 2 exactly.
FILES = (
    SourceFile("regions.csv", "regions", ("region_code", "name", "purchasing_power_index")),
    SourceFile(
        "stores.csv",
        "stores",
        ("store_code", "name", "channel", "city", "region_code", "size_m2", "opened_on"),
    ),
    SourceFile("categories.csv", "categories", ("category_code", "name")),
    SourceFile(
        "products.csv",
        "products",
        ("sku", "name", "category_code", "list_price", "purchase_currency"),
    ),
    SourceFile("customers.csv", "customers", ("customer_code", "region_code", "registered_on")),
    SourceFile(
        "promotions.csv",
        "promotions",
        ("promo_code", "name", "starts_on", "ends_on", "category_code", "sku", "discount_pct"),
    ),
    SourceFile(
        "purchases.csv",
        "purchases",
        ("purchase_code", "sku", "purchase_date", "quantity", "unit_cost", "currency"),
    ),
    SourceFile("orders.csv", "orders", ("order_code", "store_code", "customer_code", "ordered_at")),
    SourceFile(
        "order_lines.csv",
        "order_lines",
        ("order_code", "line_no", "sku", "quantity", "unit_price", "promo_code"),
    ),
    SourceFile("budgets.csv", "budgets", ("store_code", "month", "revenue_plan")),
)
RATES_FILE = SourceFile("fx_eur_pln.csv", "fx_rates", ("rate_date", "mid_rate", "table_no"))

# The whole import runs as one statement; hosted databases may default to a short timeout.
STATEMENT_TIMEOUT = "15min"


class ImportFailed(Exception):
    """A problem with the input files or the target org, reported without a traceback."""


@dataclass(frozen=True)
class ImportResult:
    run_id: int
    status: str
    rows_read: int
    rows_valid: int
    rows_rejected: int
    seconds: float
    rejected_by_file: dict[str, int]


def database_url(explicit: str | None = None) -> str:
    if explicit:
        return explicit
    try:
        from dotenv import load_dotenv

        load_dotenv(Path(".env"))
    except ModuleNotFoundError:  # pragma: no cover - dotenv is a declared dependency
        pass
    return os.environ.get("DATABASE_URL", LOCAL_DATABASE_URL)


def dataset_period(data_dir: Path) -> tuple[date, date] | None:
    """The period the dataset was generated for, from its _truth.json (None if absent)."""
    truth = data_dir / "_truth.json"
    if not truth.is_file():
        return None
    config = json.loads(truth.read_text(encoding="utf-8")).get("config", {})
    try:
        return date.fromisoformat(config["start_date"]), date.fromisoformat(config["end_date"])
    except (KeyError, TypeError, ValueError) as e:
        raise ImportFailed(f"{truth}: brak poprawnego okresu w config ({e})") from e


def read_rows(path: Path, expected: tuple[str, ...]) -> Iterator[list[str | None]]:
    """Yield data rows; empty fields become None (SQL NULL). Checks the header first."""
    with path.open(encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        if header is None:
            raise ImportFailed(f"{path.name}: pusty plik (brak nagłówka)")
        if tuple(header) != expected:
            raise ImportFailed(
                f"{path.name}: nieprawidłowy nagłówek {header}, oczekiwano {list(expected)}"
            )
        for line_no, row in enumerate(reader, start=2):
            if len(row) != len(expected):
                raise ImportFailed(
                    f"{path.name}, linia {line_no}: {len(row)} pól zamiast {len(expected)}"
                )
            yield [v if v != "" else None for v in row]


def _copy(cur: psycopg.Cursor, run_id: int, source: SourceFile, path: Path) -> int:
    stmt = sql.SQL("COPY staging.{table} ({cols}) FROM STDIN").format(
        table=sql.Identifier(source.table),
        cols=sql.SQL(", ").join(
            sql.Identifier(c) for c in ("import_run_id", "row_no", *source.columns)
        ),
    )
    count = 0
    with cur.copy(stmt) as copy:
        for count, row in enumerate(read_rows(path, source.columns), start=1):
            copy.write_row((run_id, count, *row))
    return count


def _vacuum_staging(conn: psycopg.Connection) -> None:
    """Reclaim the ~700k dead rows each run leaves in staging after deleting its rows.

    Without it the next import scans them (measured: 8 s -> 64 s after a few runs) and they
    occupy free-tier space until autovacuum gets to them. VACUUM cannot run in a transaction,
    so this switches the connection to autocommit.
    """
    conn.autocommit = True
    try:
        for f in (RATES_FILE, *FILES):
            conn.execute(sql.SQL("vacuum (analyze) staging.{}").format(sql.Identifier(f.table)))
    finally:
        conn.autocommit = False


def run_import(
    data_dir: Path,
    rates_path: Path,
    org_slug: str,
    period_start: date,
    period_end: date,
    source: str,
    url: str,
) -> ImportResult:
    """Create a run, stage every file and process it. Failed runs are logged as `failed`."""
    paths = {f.name: data_dir / f.name for f in FILES}
    paths[RATES_FILE.name] = rates_path
    missing = [str(p) for p in paths.values() if not p.is_file()]
    if missing:
        raise ImportFailed("brak plików: " + ", ".join(missing))

    with psycopg.connect(url) as conn:
        conn.execute(sql.SQL("set statement_timeout = {}").format(sql.Literal(STATEMENT_TIMEOUT)))
        org = conn.execute("select id from public.orgs where slug = %s", (org_slug,)).fetchone()
        if org is None:
            raise ImportFailed(f"organizacja „{org_slug}” nie istnieje")
        run_id = conn.execute(
            """insert into public.import_runs (org_id, source, period_start, period_end)
               values (%s, %s, %s, %s) returning id""",
            (org[0], source, period_start, period_end),
        ).fetchone()[0]
        conn.commit()  # the run is visible (status running) even if the rest fails

        try:
            with conn.cursor() as cur:
                for f in (RATES_FILE, *FILES):
                    _copy(cur, run_id, f, paths[f.name])
                cur.execute("select * from private.process_import(%s)", (run_id,))
            conn.commit()
        except Exception as e:
            conn.rollback()
            conn.execute(
                """update public.import_runs
                   set status = 'failed', finished_at = clock_timestamp(), error_message = %s
                   where id = %s""",
                (str(e)[:2000], run_id),
            )
            # Rows staged before the failure must not stay behind (free-tier size).
            for f in (RATES_FILE, *FILES):
                conn.execute(
                    sql.SQL("delete from staging.{} where import_run_id = %s").format(
                        sql.Identifier(f.table)
                    ),
                    (run_id,),
                )
            conn.commit()
            _vacuum_staging(conn)
            raise

        _vacuum_staging(conn)
        run = conn.execute(
            """select status::text, rows_read, rows_valid, rows_rejected,
                      extract(epoch from finished_at - started_at)::float
               from public.import_runs where id = %s""",
            (run_id,),
        ).fetchone()
        by_file = dict(
            conn.execute(
                """select file, count(distinct row_no)::int from public.import_errors
                   where import_run_id = %s group by file order by file""",
                (run_id,),
            ).fetchall()
        )
    status, read, valid, rejected, seconds = run
    return ImportResult(run_id, status, read, valid, rejected, seconds, by_file)
