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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
