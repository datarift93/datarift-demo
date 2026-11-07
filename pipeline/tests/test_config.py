from datetime import date
from pathlib import Path

import pytest
from pydantic import ValidationError

from datarift_pipeline.cli import main
from datarift_pipeline.config import GeneratorConfig, load_config

PIPELINE_DIR = Path(__file__).resolve().parents[1]

VALID = {
    "seed": 42,
    "start_date": date(2024, 1, 1),
    "end_date": date(2025, 12, 31),
    "store_count": 25,
    "online_store": True,
    "customer_count": 20000,
    "scale": 1.0,
}

VALID_TOML = """
seed = 1
start_date = 2025-01-01
end_date = 2025-12-31
store_count = 5
customer_count = 10
scale = 1.0
"""


def test_default_config_file_is_valid(monkeypatch):
    monkeypatch.chdir(PIPELINE_DIR)
    config = load_config()
    assert config.days >= 365


def test_config_path_from_env(monkeypatch, tmp_path: Path):
    path = tmp_path / "custom.toml"
    path.write_text(VALID_TOML)
    monkeypatch.setenv("DATARIFT_CONFIG", str(path))
    assert load_config().store_count == 5


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("store_count", 0),
        ("store_count", 101),
        ("customer_count", 0),
        ("customer_count", 200_001),
        ("scale", 0),
        ("scale", 3.5),
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


def test_accepts_exactly_one_calendar_year():
    config = GeneratorConfig(**{**VALID, "start_date": date(2025, 1, 1)})
    assert config.days == 365


def test_days_counts_both_ends():
    assert GeneratorConfig(**VALID).days == 731  # 2024 is a leap year


def test_rejects_unknown_keys(tmp_path: Path):
    path = tmp_path / "bad.toml"
    path.write_text(VALID_TOML + "stores = 5\n")
    with pytest.raises(ValidationError):
        load_config(path)


def test_cli_prints_config(tmp_path: Path, capsys):
    path = tmp_path / "config.toml"
    path.write_text(VALID_TOML)
    assert main(["config", "--path", str(path)]) == 0
    out = capsys.readouterr().out
    assert "store_count = 5" in out
    assert "days = 365" in out


def test_cli_reports_invalid_config(tmp_path: Path, capsys):
    path = tmp_path / "config.toml"
    path.write_text(VALID_TOML.replace("store_count = 5", "store_count = 0"))
    assert main(["config", "--path", str(path)]) == 2
    err = capsys.readouterr().err
    assert "invalid config" in err
    assert "store_count" in err


def test_cli_reports_missing_file(tmp_path: Path, capsys):
    assert main(["config", "--path", str(tmp_path / "missing.toml")]) == 2
    assert "config file not found" in capsys.readouterr().err
