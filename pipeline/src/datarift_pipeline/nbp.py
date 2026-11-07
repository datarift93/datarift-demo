"""Fetch real EUR/PLN mid rates (table A) from the NBP API and keep them in a CSV in the repo.

The generator reads `data/fx_eur_pln.csv`, not the API, so the same seed gives the same data
even years later. A purchase uses the rate from its date, or from the last business day
before it (`rate_on`).
"""

import bisect
import csv
import json
import urllib.error
import urllib.request
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from datetime import date, timedelta
from decimal import Decimal
from pathlib import Path

API_URL = "https://api.nbp.pl/api/exchangerates/rates/a/eur/{start}/{end}/?format=json"
MAX_DAYS_PER_REQUEST = 93
DEFAULT_RATES_PATH = Path("data/fx_eur_pln.csv")
CSV_COLUMNS = ("rate_date", "mid_rate", "table_no")


@dataclass(frozen=True)
class Rate:
    rate_date: date
    mid_rate: Decimal
    table_no: str


# Takes a URL, returns the parsed JSON body or None for "no data in this range" (HTTP 404).
Fetcher = Callable[[str], dict | None]


def http_fetch(url: str) -> dict | None:
    request = urllib.request.Request(
        url, headers={"Accept": "application/json", "User-Agent": "datarift-pipeline"}
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as e:
        if e.code == 404:  # NBP answers 404 when a range has no publication days
            return None
        raise


def date_chunks(start: date, end: date, max_days: int = MAX_DAYS_PER_REQUEST) -> Iterator[tuple]:
    """Split [start, end] (inclusive) into ranges of at most `max_days` days."""
    if end < start:
        raise ValueError("end must not be before start")
    chunk_start = start
    while chunk_start <= end:
        chunk_end = min(chunk_start + timedelta(days=max_days - 1), end)
        yield chunk_start, chunk_end
        chunk_start = chunk_end + timedelta(days=1)


def parse_response(body: dict) -> list[Rate]:
    return [
        Rate(
            rate_date=date.fromisoformat(item["effectiveDate"]),
            # str() keeps the published 4 decimal places exactly
            mid_rate=Decimal(str(item["mid"])).quantize(Decimal("0.0001")),
            table_no=item["no"],
        )
        for item in body["rates"]
    ]


def fetch_rates(start: date, end: date, fetch: Fetcher | None = None) -> list[Rate]:
    fetch = fetch or http_fetch
    rates: dict[date, Rate] = {}
    for chunk_start, chunk_end in date_chunks(start, end):
        body = fetch(API_URL.format(start=chunk_start.isoformat(), end=chunk_end.isoformat()))
        if body is not None:
            for rate in parse_response(body):
                rates[rate.rate_date] = rate
    return [rates[d] for d in sorted(rates)]


def write_rates(rates: list[Rate], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f, lineterminator="\n")
        writer.writerow(CSV_COLUMNS)
        for r in rates:
            writer.writerow((r.rate_date.isoformat(), f"{r.mid_rate:.4f}", r.table_no))


def read_rates(path: Path = DEFAULT_RATES_PATH) -> list[Rate]:
    with path.open(encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        if tuple(reader.fieldnames or ()) != CSV_COLUMNS:
            raise ValueError(f"{path}: expected columns {CSV_COLUMNS}, got {reader.fieldnames}")
        rates = [
            Rate(date.fromisoformat(row["rate_date"]), Decimal(row["mid_rate"]), row["table_no"])
            for row in reader
        ]
    dates = [r.rate_date for r in rates]
    if dates != sorted(set(dates)):
        raise ValueError(f"{path}: rate dates must be unique and sorted")
    return rates


class RateTable:
    """Lookup: the rate for a date, or for the last publication day before it."""

    def __init__(self, rates: list[Rate]):
        if not rates:
            raise ValueError("no rates")
        self._rates = sorted(rates, key=lambda r: r.rate_date)
        self._dates = [r.rate_date for r in self._rates]

    @property
    def first_date(self) -> date:
        return self._dates[0]

    @property
    def last_date(self) -> date:
        return self._dates[-1]

    def rate_on(self, day: date) -> Rate:
        i = bisect.bisect_right(self._dates, day) - 1
        if i < 0:
            raise LookupError(f"no NBP rate on or before {day} (first is {self.first_date})")
        return self._rates[i]

    def covers(self, start: date, end: date) -> bool:
        """True when every day in [start, end] has a rate on or shortly (<= 7 days) before it."""
        return self.first_date <= start and (end - self.last_date).days <= 7

    def mean_rate(self, start: date, end: date) -> float:
        values = [float(r.mid_rate) for r in self._rates if start <= r.rate_date <= end]
        if not values:
            raise LookupError(f"no NBP rates between {start} and {end}")
        return sum(values) / len(values)
