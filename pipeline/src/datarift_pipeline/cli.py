"""Command-line entry point: `uv run datarift-pipeline <command>`."""

import argparse
import sys
from pathlib import Path

from pydantic import ValidationError

from datarift_pipeline.config import load_config


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="datarift-pipeline")
    sub = parser.add_subparsers(dest="command", required=True)

    show = sub.add_parser("config", help="validate and print the generator config")
    show.add_argument("--path", type=Path, default=None, help="config file (TOML)")

    args = parser.parse_args(argv)

    if args.command == "config":
        try:
            config = load_config(args.path)
        except FileNotFoundError as e:
            print(f"error: config file not found: {e.filename}", file=sys.stderr)
            return 2
        except ValidationError as e:
            print(f"error: invalid config:\n{e}", file=sys.stderr)
            return 2
        for key, value in config.model_dump().items():
            print(f"{key} = {value}")
        print(f"days = {config.days}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
