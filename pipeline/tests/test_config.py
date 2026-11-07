from datetime import date
from pathlib import Path

import pytest
from pydantic import ValidationError

from datarift_pipeline.cli import main
from datarift_pipeline.config import GeneratorConfig, load_config

VALID = {
    "seed": 42,
    "start_date": date(2024, 1, 1),
    "end_date": date(2025, 12, 31),
    "store_count": 25,
    "online_store": True,
    "customer_count": 20000,
    "scale": 1.0,
}


def test_default_config_file_is_valid():
    config = load_config()
    assert config.store_count == 25
    assert config.days == 731  # 2024 is a leap year


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("store_count", 0),
        ("store_count", 101),
        ("customer_count", 0),
        ("scale", 0),
        ("seed", -1),
    ],
)
def test_rejects_out_of_range_values(field, value):
    with pytest.raises(ValidationError):
        GeneratorConfig(**{**VALID, field: value})


def test_rejects_end_before_start():
    with pytest.raises(ValidationError, match="end_date must be after start_date"):
        GeneratorConfig(**{**VALID, "end_date": date(2023, 1, 1)})


def test_rejects_range_shorter_than_a_year():
    with pytest.raises(ValidationError, match="at least one full year"):
        GeneratorConfig(**{**VALID, "end_date": date(2024, 6, 30)})


def test_rejects_unknown_keys(tmp_path: Path):
    path = tmp_path / "bad.toml"
    path.write_text(
        "seed = 1\nstart_date = 2024-01-01\nend_date = 2025-12-31\nstore_count = 5\n"
        "customer_count = 10\nscale = 1.0\nstores = 5\n"
    )
    with pytest.raises(ValidationError):
        load_config(path)


def test_cli_prints_config(capsys):
    assert main(["config"]) == 0
    out = capsys.readouterr().out
    assert "store_count = 25" in out
    assert "days = 731" in out
