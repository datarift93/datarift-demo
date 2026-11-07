"""Command-line entry point: `uv run datarift-pipeline <command>`."""

import argparse
from pathlib import Path

from datarift_pipeline.config import DEFAULT_CONFIG_PATH, load_config


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="datarift-pipeline")
    sub = parser.add_subparsers(dest="command", required=True)

    show = sub.add_parser("config", help="validate and print the generator config")
    show.add_argument("--path", type=Path, default=DEFAULT_CONFIG_PATH)

    args = parser.parse_args(argv)

    if args.command == "config":
        config = load_config(args.path)
        for key, value in config.model_dump().items():
            print(f"{key} = {value}")
        print(f"days = {config.days}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
