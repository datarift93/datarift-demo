"""Command-line entry point: `uv run datarift-pipeline <command>`."""

import argparse
import sys
import time
from datetime import timedelta
from pathlib import Path

from pydantic import ValidationError

from datarift_pipeline import nbp
from datarift_pipeline.config import GeneratorConfig, load_config

# Extra days fetched before the purchase window, so a purchase on its first day (maybe a
# weekend or holiday) still has an earlier publication day to fall back to.
RATES_MARGIN_DAYS = 7


def _load(path: Path | None) -> GeneratorConfig | None:
    try:
        return load_config(path)
    except FileNotFoundError as e:
        print(f"error: config file not found: {e.filename}", file=sys.stderr)
    except ValidationError as e:
        print(f"error: invalid config:\n{e}", file=sys.stderr)
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="datarift-pipeline")
    sub = parser.add_subparsers(dest="command", required=True)

    show = sub.add_parser("config", help="validate and print the generator config")
    show.add_argument("--path", type=Path, default=None, help="config file (TOML)")

    fetch = sub.add_parser("fetch-rates", help="fetch EUR/PLN mid rates from the NBP API")
    fetch.add_argument("--path", type=Path, default=None, help="config file (TOML)")
    fetch.add_argument("--out", type=Path, default=nbp.DEFAULT_RATES_PATH)

    gen = sub.add_parser("generate", help="generate the demo dataset (CSV + _truth.json)")
    gen.add_argument("--path", type=Path, default=None, help="config file (TOML)")
    gen.add_argument("--rates", type=Path, default=nbp.DEFAULT_RATES_PATH)
    gen.add_argument("--out", type=Path, default=Path("out"))

    imp = sub.add_parser("import", help="import generated CSVs into the database")
    imp.add_argument("--path", type=Path, default=None, help="config file (TOML)")
    imp.add_argument("--data", type=Path, default=Path("out"), help="directory with the CSVs")
    imp.add_argument("--rates", type=Path, default=nbp.DEFAULT_RATES_PATH)
    imp.add_argument("--org", default="wisla-demo", help="target organization slug")
    imp.add_argument(
        "--database-url", default=None, help="default: $DATABASE_URL, then local Supabase"
    )

    args = parser.parse_args(argv)
    config = _load(args.path)
    if config is None:
        return 2

    if args.command == "config":
        for key, value in config.model_dump().items():
            print(f"{key} = {value}")
        print(f"days = {config.days}")

    elif args.command == "fetch-rates":
        start = config.purchases_start - timedelta(days=RATES_MARGIN_DAYS)
        rates = nbp.fetch_rates(start, config.end_date)
        nbp.write_rates(rates, args.out)
        print(f"{len(rates)} rates {rates[0].rate_date}..{rates[-1].rate_date} -> {args.out}")

    elif args.command == "generate":
        from datarift_pipeline.generator import generate  # numpy import only when needed

        try:
            rates = nbp.read_rates(args.rates)
        except FileNotFoundError:
            print(f"error: rates file not found: {args.rates} (run fetch-rates)", file=sys.stderr)
            return 2
        started = time.perf_counter()
        counts = generate(config, rates, args.out)
        elapsed = time.perf_counter() - started
        for name, count in counts.items():
            print(f"{name:<20} {count:>9,}")
        print(f"generated in {elapsed:.1f} s -> {args.out}")

    elif args.command == "import":
        from datarift_pipeline import importer  # psycopg import only when needed

        url = importer.database_url(args.database_url)
        try:
            # The period the data was generated for wins over the current config file.
            start, end = importer.dataset_period(args.data) or (config.start_date, config.end_date)
            source = f"{args.data.name}/ ({start}..{end})"
            result = importer.run_import(args.data, args.rates, args.org, start, end, source, url)
        except importer.ImportFailed as e:
            print(f"error: {e}", file=sys.stderr)
            return 2
        print(f"import run {result.run_id}: {result.status} in {result.seconds:.1f} s")
        print(
            f"rows read {result.rows_read:,}, valid {result.rows_valid:,}, "
            f"rejected {result.rows_rejected:,}"
        )
        for name, count in result.rejected_by_file.items():
            print(f"  rejected in {name:<18} {count:>7,}")
        return 0 if result.status in ("success", "partial") else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
