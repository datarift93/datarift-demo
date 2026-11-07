import json
from datetime import date, timedelta
from decimal import Decimal
from pathlib import Path

import pytest

from datarift_pipeline import nbp
from datarift_pipeline.cli import main
from datarift_pipeline.config import load_config

FIXTURES = Path(__file__).parent / "fixtures"
PIPELINE_DIR = Path(__file__).resolve().parents[1]
RECORDED = json.loads((FIXTURES / "nbp_eur_2025-12-29_2026-01-05.json").read_text())


def test_parse_recorded_response():
    rates = nbp.parse_response(RECORDED)
    assert [r.rate_date for r in rates] == [
        date(2025, 12, 29),
        date(2025, 12, 30),
        date(2025, 12, 31),
        date(2026, 1, 2),
        date(2026, 1, 5),
    ]
    assert rates[0].mid_rate == Decimal("4.2274")
    assert rates[0].table_no == "249/A/NBP/2025"
    assert rates[-1].mid_rate == Decimal("4.2110")  # trailing zero kept


def test_date_chunks_respect_api_limit():
    start, end = date(2023, 8, 28), date(2025, 12, 31)
    chunks = list(nbp.date_chunks(start, end))
    assert chunks[0][0] == start and chunks[-1][1] == end
    for (_, b), (c, _) in zip(chunks, chunks[1:], strict=False):
        assert c == b + timedelta(days=1)
    assert all((b - a).days + 1 <= nbp.MAX_DAYS_PER_REQUEST for a, b in chunks)


def test_fetch_rates_uses_chunks_and_skips_empty_ranges():
    urls = []

    def fake_fetch(url: str):
        urls.append(url)
        return RECORDED if "2025-12-29" in url else None  # other ranges: 404

    rates = nbp.fetch_rates(date(2025, 12, 29), date(2026, 4, 30), fetch=fake_fetch)
    assert len(urls) == 2
    assert urls[0] == nbp.API_URL.format(start="2025-12-29", end="2026-03-31")
    assert len(rates) == 5


def test_fetch_rates_cli_writes_csv(tmp_path: Path, monkeypatch):
    config = tmp_path / "config.toml"
    config.write_text(
        "seed = 1\nstart_date = 2025-01-01\nend_date = 2025-12-31\n"
        "store_count = 5\ncustomer_count = 10\nscale = 1.0\n"
    )
    monkeypatch.setattr(nbp, "http_fetch", lambda url: RECORDED)
    out = tmp_path / "fx.csv"
    assert main(["fetch-rates", "--path", str(config), "--out", str(out)]) == 0
    assert nbp.read_rates(out) == nbp.parse_response(RECORDED)


def test_write_and_read_roundtrip(tmp_path: Path):
    path = tmp_path / "fx.csv"
    rates = nbp.parse_response(RECORDED)
    nbp.write_rates(rates, path)
    assert path.read_text().splitlines()[:2] == [
        "rate_date,mid_rate,table_no",
        "2025-12-29,4.2274,249/A/NBP/2025",
    ]
    assert nbp.read_rates(path) == rates


def test_rate_on_falls_back_to_last_business_day():
    table = nbp.RateTable(nbp.parse_response(RECORDED))
    assert table.rate_on(date(2025, 12, 30)).table_no == "250/A/NBP/2025"
    # 1 Jan (holiday) and the weekend 3-4 Jan use the last publication before them.
    assert table.rate_on(date(2026, 1, 1)).rate_date == date(2025, 12, 31)
    assert table.rate_on(date(2026, 1, 4)).rate_date == date(2026, 1, 2)
    with pytest.raises(LookupError):
        table.rate_on(date(2025, 12, 28))


def test_read_rates_rejects_wrong_columns(tmp_path: Path):
    path = tmp_path / "fx.csv"
    path.write_text("date,rate\n2025-01-02,4.27\n")
    with pytest.raises(ValueError, match="expected columns"):
        nbp.read_rates(path)


def test_committed_rates_cover_default_config(monkeypatch):
    monkeypatch.chdir(PIPELINE_DIR)
    config = load_config()
    rates = nbp.read_rates()
    table = nbp.RateTable(rates)
    assert table.covers(config.purchases_start, config.end_date)
    assert all(Decimal("3.5") < r.mid_rate < Decimal("5.5") for r in rates)
    # NBP publishes on every business day: the longest gap is Christmas 2025 (23 -> 29 Dec).
    gaps = [(b.rate_date - a.rate_date).days for a, b in zip(rates, rates[1:], strict=False)]
    assert max(gaps) <= 6
