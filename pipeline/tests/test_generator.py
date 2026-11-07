import re
import statistics
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta
from decimal import Decimal, InvalidOperation
from pathlib import Path

import pytest
from conftest import RATES_PATH, Dataset, load_dataset
from metrics import (
    order_day,
    order_index,
    order_revenue,
    retention,
    revenue_by,
    top_share,
    weekly_orders,
)

from datarift_pipeline.cli import main
from datarift_pipeline.config import GeneratorConfig
from datarift_pipeline.generator import generate
from datarift_pipeline.nbp import read_rates
from datarift_pipeline.reference import REGIONS

SMALL = GeneratorConfig(
    seed=7,
    start_date=date(2024, 1, 1),
    end_date=date(2024, 12, 31),
    store_count=8,
    customer_count=800,
    scale=0.1,
    product_count=120,
)

# docs/data-model.md section 2: column -> (type, nullable)
CONTRACT = {
    "regions.csv": {
        "region_code": ("text", False),
        "name": ("text", False),
        "purchasing_power_index": ("decimal", False),
    },
    "stores.csv": {
        "store_code": ("text", False),
        "name": ("text", False),
        "channel": ("store|online", False),
        "city": ("text", True),
        "region_code": ("text", True),
        "size_m2": ("int", True),
        "opened_on": ("date", False),
    },
    "categories.csv": {"category_code": ("text", False), "name": ("text", False)},
    "products.csv": {
        "sku": ("text", False),
        "name": ("text", False),
        "category_code": ("text", False),
        "list_price": ("money", False),
        "purchase_currency": ("PLN|EUR", False),
    },
    "customers.csv": {
        "customer_code": ("text", False),
        "region_code": ("text", False),
        "registered_on": ("date", False),
    },
    "promotions.csv": {
        "promo_code": ("text", False),
        "name": ("text", False),
        "starts_on": ("date", False),
        "ends_on": ("date", False),
        "category_code": ("text", True),
        "sku": ("text", True),
        "discount_pct": ("decimal", False),
    },
    "purchases.csv": {
        "purchase_code": ("text", False),
        "sku": ("text", False),
        "purchase_date": ("date", False),
        "quantity": ("int", False),
        "unit_cost": ("money", False),
        "currency": ("PLN|EUR", False),
    },
    "orders.csv": {
        "order_code": ("text", False),
        "store_code": ("text", False),
        "customer_code": ("text", True),
        "ordered_at": ("timestamp", False),
    },
    "order_lines.csv": {
        "order_code": ("text", False),
        "line_no": ("int", False),
        "sku": ("text", False),
        "quantity": ("int", False),
        "unit_price": ("money", False),
        "promo_code": ("text", True),
    },
    "budgets.csv": {
        "store_code": ("text", False),
        "month": ("date", False),
        "revenue_plan": ("money", False),
    },
}
TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+0[12]:00$")
MONEY = re.compile(r"^-?\d+\.\d{2}$")


def _valid(kind: str, value: str) -> bool:
    try:
        if kind == "text":
            return value.strip() == value and value != ""
        if kind == "int":
            return str(int(value)) == value
        if kind == "decimal":
            Decimal(value)
            return True
        if kind == "money":
            return bool(MONEY.match(value))
        if kind == "date":
            return date.fromisoformat(value).isoformat() == value
        if kind == "timestamp":
            datetime.fromisoformat(value)
            return bool(TIMESTAMP.match(value))
        return value in kind.split("|")
    except (ValueError, InvalidOperation):
        return False


def _dirty(ds: Dataset, file: str) -> dict[int, str]:
    return {r["row_no"]: r["kind"] for r in ds.truth["dirty_rows"] if r["file"] == file}


# --- determinism and CLI ------------------------------------------------------------------


def test_same_seed_gives_byte_identical_output(tmp_path: Path):
    rates = read_rates(RATES_PATH)
    generate(SMALL, rates, tmp_path / "a")
    generate(SMALL, rates, tmp_path / "b")
    files = sorted(p.name for p in (tmp_path / "a").iterdir())
    assert files == sorted([*CONTRACT, "_truth.json"])
    for name in files:
        assert (tmp_path / "a" / name).read_bytes() == (tmp_path / "b" / name).read_bytes(), name


def test_different_seed_gives_different_data(tmp_path: Path):
    rates = read_rates(RATES_PATH)
    generate(SMALL, rates, tmp_path / "a")
    generate(SMALL.model_copy(update={"seed": 8}), rates, tmp_path / "b")
    a = (tmp_path / "a" / "order_lines.csv").read_bytes()
    assert a != (tmp_path / "b" / "order_lines.csv").read_bytes()


def test_cli_generate(tmp_path: Path, capsys):
    config = tmp_path / "config.toml"
    config.write_text(
        "seed = 3\nstart_date = 2024-01-01\nend_date = 2024-12-31\nstore_count = 6\n"
        "customer_count = 300\nscale = 0.05\nproduct_count = 60\n"
    )
    out = tmp_path / "out"
    assert (
        main(["generate", "--path", str(config), "--rates", str(RATES_PATH), "--out", str(out)])
        == 0
    )
    assert "order_lines.csv" in capsys.readouterr().out
    assert (out / "_truth.json").exists()


def test_cli_generate_without_rates_file(tmp_path: Path, capsys):
    args = ["generate", "--rates", str(tmp_path / "missing.csv"), "--out", str(tmp_path)]
    assert main(args) == 2
    assert "fetch-rates" in capsys.readouterr().err


def test_generate_rejects_rates_not_covering_purchases(tmp_path: Path):
    rates = [r for r in read_rates(RATES_PATH) if r.rate_date >= date(2024, 1, 1)]
    with pytest.raises(ValueError, match="do not cover"):
        generate(SMALL, rates, tmp_path)


def test_config_rejects_too_many_flagged_stores():
    with pytest.raises(ValueError, match="exceeds store_count"):
        SMALL.model_validate({**SMALL.model_dump(), "store_count": 4})


# --- contract -----------------------------------------------------------------------------


def test_default_volume(default_dataset: Dataset):
    lines = len(default_dataset.clean("order_lines.csv"))
    orders = len(default_dataset.clean("orders.csv"))
    assert 300_000 <= lines <= 600_000
    assert 150_000 <= orders <= 250_000
    assert len(default_dataset.rows["customers.csv"]) == 20_000
    assert len(default_dataset.rows["products.csv"]) == 400
    assert len(default_dataset.rows["regions.csv"]) == 16
    assert 6 <= len(default_dataset.rows["categories.csv"]) <= 8


def test_columns_and_types_match_contract(default_dataset: Dataset):
    for name, columns in CONTRACT.items():
        assert default_dataset.header[name] == list(columns), name
        for i, row in enumerate(default_dataset.rows[name], start=1):
            for column, (kind, nullable) in columns.items():
                value = row[column]
                if value == "":
                    assert nullable, f"{name} row {i}: {column} is empty"
                else:
                    assert _valid(kind, value), f"{name} row {i}: {column}={value!r}"


def test_files_are_utf8_without_bom(default_dataset: Dataset):
    for name in CONTRACT:
        raw = (default_dataset.path / name).read_bytes()
        assert not raw.startswith(b"\xef\xbb\xbf")
        assert b"\r\n" not in raw[:10_000]
    assert "Kraków" in (default_dataset.path / "stores.csv").read_text(encoding="utf-8")


def test_primary_keys_are_unique_in_clean_rows(default_dataset: Dataset):
    keys = {
        "regions.csv": ("region_code",),
        "stores.csv": ("store_code",),
        "categories.csv": ("category_code",),
        "products.csv": ("sku",),
        "customers.csv": ("customer_code",),
        "promotions.csv": ("promo_code",),
        "purchases.csv": ("purchase_code",),
        "orders.csv": ("order_code",),
        "order_lines.csv": ("order_code", "line_no"),
        "budgets.csv": ("store_code", "month"),
    }
    for name, cols in keys.items():
        values = [tuple(r[c] for c in cols) for r in default_dataset.clean(name)]
        assert len(values) == len(set(values)), name


def test_referential_integrity_of_clean_rows(default_dataset: Dataset):
    ds = default_dataset
    codes = lambda f, c: {r[c] for r in ds.rows[f]}  # noqa: E731
    regions, stores = codes("regions.csv", "region_code"), codes("stores.csv", "store_code")
    categories, skus = codes("categories.csv", "category_code"), codes("products.csv", "sku")
    customers, promos = (
        codes("customers.csv", "customer_code"),
        codes("promotions.csv", "promo_code"),
    )
    orders = {r["order_code"] for r in ds.clean("orders.csv")}

    assert {r["region_code"] for r in ds.rows["stores.csv"] if r["region_code"]} <= regions
    assert {r["category_code"] for r in ds.rows["products.csv"]} <= categories
    assert {r["region_code"] for r in ds.rows["customers.csv"]} <= regions
    assert {
        r["category_code"] for r in ds.rows["promotions.csv"] if r["category_code"]
    } <= categories
    assert {r["sku"] for r in ds.rows["promotions.csv"] if r["sku"]} <= skus
    assert {r["sku"] for r in ds.rows["purchases.csv"]} == skus  # every product is bought
    assert {r["store_code"] for r in ds.clean("orders.csv")} <= stores
    assert {r["customer_code"] for r in ds.clean("orders.csv") if r["customer_code"]} <= customers
    lines = ds.clean("order_lines.csv")
    assert {r["order_code"] for r in lines} == orders  # and every order has a line
    assert {r["sku"] for r in lines} <= skus
    assert {r["promo_code"] for r in lines if r["promo_code"]} <= promos
    assert {r["store_code"] for r in ds.rows["budgets.csv"]} == stores


def test_clean_rows_are_consistent(default_dataset: Dataset):
    ds = default_dataset
    start = date.fromisoformat(ds.truth["config"]["start_date"])
    end = date.fromisoformat(ds.truth["config"]["end_date"])
    registered = {c["customer_code"]: c["registered_on"] for c in ds.rows["customers.csv"]}
    for o in ds.clean("orders.csv"):
        assert start <= order_day(o) <= end
        if o["store_code"] == "ONLINE":
            assert o["customer_code"], "online orders always have a customer account"
        if o["customer_code"]:
            assert registered[o["customer_code"]] <= o["ordered_at"][:10]
    for line in ds.clean("order_lines.csv"):
        assert int(line["quantity"]) > 0 and Decimal(line["unit_price"]) > 0
    for p in ds.rows["purchases.csv"]:
        assert int(p["quantity"]) > 0 and Decimal(p["unit_cost"]) > 0
        assert date.fromisoformat(p["purchase_date"]).weekday() < 5
    for p in ds.rows["promotions.csv"]:
        assert (
            start <= date.fromisoformat(p["starts_on"]) <= date.fromisoformat(p["ends_on"]) <= end
        )
        assert 0 < Decimal(p["discount_pct"]) < 1
    for b in ds.rows["budgets.csv"]:
        assert b["month"].endswith("-01") and Decimal(b["revenue_plan"]) > 0


def test_timestamps_use_polish_offsets(default_dataset: Dataset):
    for o in default_dataset.clean("orders.csv"):
        month = int(o["ordered_at"][5:7])
        if month in (1, 2, 12):
            assert o["ordered_at"].endswith("+01:00")
        elif 5 <= month <= 9:
            assert o["ordered_at"].endswith("+02:00")


def test_stores_and_regions_look_real(default_dataset: Dataset):
    stores = default_dataset.rows["stores.csv"]
    physical = [s for s in stores if s["channel"] == "store"]
    assert len(physical) == 25
    assert {s["region_code"] for s in physical} == {r.code for r in REGIONS}  # all voivodeships
    for s in physical:
        city_no = re.fullmatch(r"(.+) (\d+)", s["name"])
        assert city_no and city_no[1] == s["city"]
        assert s["store_code"].endswith(f"-{int(city_no[2]):02d}")
        assert 500 <= int(s["size_m2"]) <= 4000
    online = [s for s in stores if s["channel"] == "online"]
    assert len(online) == 1 and online[0]["store_code"] == "ONLINE"
    assert online[0]["city"] == online[0]["region_code"] == online[0]["size_m2"] == ""
    names = [p["name"] for p in default_dataset.rows["products.csv"]]
    assert len(names) == len(set(names))


def test_purchases_cover_every_sale(default_dataset: Dataset):
    """unit_cost_pln at import is the weighted average of the 90 days before the sale."""
    ds = default_dataset
    start = date.fromisoformat(ds.truth["config"]["start_date"])
    end = date.fromisoformat(ds.truth["config"]["end_date"])
    by_sku = defaultdict(list)
    for p in ds.rows["purchases.csv"]:
        by_sku[p["sku"]].append(date.fromisoformat(p["purchase_date"]))
    for sku, days in by_sku.items():
        days.sort()
        assert days[0] <= start - timedelta(days=30), sku
        assert days[-1] >= end - timedelta(days=50), sku
        assert max((b - a).days for a, b in zip(days, days[1:], strict=False)) <= 60, sku


def test_eur_share_of_products(default_dataset: Dataset):
    products = default_dataset.rows["products.csv"]
    share = sum(p["purchase_currency"] == "EUR" for p in products) / len(products)
    assert 0.25 <= share <= 0.35
    currency = {p["sku"]: p["purchase_currency"] for p in products}
    assert all(p["currency"] == currency[p["sku"]] for p in default_dataset.rows["purchases.csv"])


# --- dirty rows ----------------------------------------------------------------------------


def _line_defects(ds: Dataset) -> dict[int, str]:
    skus = {p["sku"] for p in ds.rows["products.csv"]}
    seen = set()
    found = {}
    for i, r in enumerate(ds.rows["order_lines.csv"], start=1):
        key = (r["order_code"], r["line_no"])
        if key in seen:
            found[i] = "duplicate"
        elif r["sku"] not in skus:
            found[i] = "unknown_sku"
        elif int(r["quantity"]) <= 0:
            found[i] = "zero_quantity"
        elif Decimal(r["unit_price"]) < 0:
            found[i] = "negative_price"
        seen.add(key)
    return found


def test_dirty_rows_are_exactly_those_in_truth(default_dataset: Dataset):
    ds = default_dataset
    assert _line_defects(ds) == _dirty(ds, "order_lines.csv")

    start = date.fromisoformat(ds.truth["config"]["start_date"])
    end = date.fromisoformat(ds.truth["config"]["end_date"])
    out_of_range = {
        i: "date_out_of_range"
        for i, o in enumerate(ds.rows["orders.csv"], start=1)
        if not start <= order_day(o) <= end
    }
    assert out_of_range == _dirty(ds, "orders.csv")
    assert {r["file"] for r in ds.truth["dirty_rows"]} == {"orders.csv", "order_lines.csv"}


def test_dirty_row_rate_and_kinds(default_dataset: Dataset):
    ds = default_dataset
    total = len(ds.rows["orders.csv"]) + len(ds.rows["order_lines.csv"])
    dirty = ds.truth["dirty_rows"]
    assert len(dirty) == pytest.approx(0.002 * total, rel=0.02)
    kinds = Counter(r["kind"] for r in dirty)
    assert set(kinds) == {
        "unknown_sku",
        "zero_quantity",
        "negative_price",
        "duplicate",
        "date_out_of_range",
    }
    assert max(kinds.values()) - min(kinds.values()) <= 1
    # Broken order lines point at real orders, so only the broken field fails validation.
    clean_orders = {o["order_code"] for o in ds.clean("orders.csv")}
    assert all(r["order_code"] in clean_orders for r in dirty if r["file"] == "order_lines.csv")


def test_no_dirty_rows_when_rate_is_zero(tmp_path: Path):
    generate(SMALL.model_copy(update={"dirty_row_rate": 0.0}), read_rates(RATES_PATH), tmp_path)
    ds = load_dataset(tmp_path)
    assert ds.truth["dirty_rows"] == []
    assert _line_defects(ds) == {}


# --- planted signals (docs/data-model.md section 4) ----------------------------------------


def test_yearly_seasonality(default_dataset: Dataset):
    month = revenue_by(default_dataset, lambda o: o["ordered_at"][:7])
    for year in ("2024", "2025"):
        assert month[f"{year}-12"] > 1.5 * month[f"{year}-02"]
        assert month[f"{year}-12"] == max(v for k, v in month.items() if k.startswith(year))
        assert month[f"{year}-01"] < month[f"{year}-04"]


def test_category_summer_seasonality(default_dataset: Dataset):
    ds = default_dataset
    category = {p["sku"]: p["category_code"] for p in ds.rows["products.csv"]}
    orders = order_index(ds)
    units = defaultdict(float)
    for line in ds.clean("order_lines.csv"):
        m = orders[line["order_code"]]["ordered_at"][5:7]
        units[(category[line["sku"]], m)] += int(line["quantity"])
    share = lambda cat, m: units[(cat, m)] / sum(v for (c, mm), v in units.items() if mm == m)  # noqa: E731
    assert share("SPORT", "07") > 1.5 * share("SPORT", "01")
    assert share("BOOKS", "08") > 1.4 * share("BOOKS", "05")
    assert share("TOYS", "12") > 1.5 * share("TOYS", "07")


def test_weekly_seasonality(default_dataset: Dataset):
    ds = default_dataset
    counts = Counter()
    evening = Counter()
    for o in ds.clean("orders.csv"):
        online = o["store_code"] == "ONLINE"
        wd = order_day(o).weekday()
        counts[(online, wd)] += 1
        if online and 19 <= int(o["ordered_at"][11:13]) <= 22:
            evening[wd] += 1
    store = [counts[(False, d)] for d in range(6)]
    assert store.index(max(store)) == 5  # Saturday
    online = [counts[(True, d)] for d in range(7)]
    assert sorted(range(7), key=lambda d: -online[d])[:2] in ([6, 0], [0, 6])  # Sun + Mon
    assert evening[0] / counts[(True, 0)] > 1.15 * evening[2] / counts[(True, 2)]


def test_stores_closed_on_ordinary_sundays_and_holidays(default_dataset: Dataset):
    ds = default_dataset
    trading = set(ds.truth["calendar"]["trading_sundays"])
    holidays = set(ds.truth["calendar"]["public_holidays_stores_closed"])
    assert "2024-12-15" in trading and "2025-12-07" in trading and "2024-12-08" not in trading
    assert "2025-12-24" in holidays and "2024-12-24" not in holidays
    store_days = Counter(
        o["ordered_at"][:10] for o in ds.clean("orders.csv") if o["store_code"] != "ONLINE"
    )
    for day in store_days:
        d = date.fromisoformat(day)
        assert day not in holidays, day
        assert d.weekday() != 6 or day in trading, day
    assert all(store_days[d] > 0 for d in trading)
    online_days = {
        o["ordered_at"][:10] for o in ds.clean("orders.csv") if o["store_code"] == "ONLINE"
    }
    assert all(d in online_days for d in holidays)  # online never closes


def test_black_friday_and_cyber_monday(default_dataset: Dataset):
    ds = default_dataset
    daily = Counter(
        (o["store_code"] == "ONLINE", o["ordered_at"][:10]) for o in ds.clean("orders.csv")
    )
    lines = ds.clean("order_lines.csv")
    for bf in ds.truth["black_friday"]:
        friday = date.fromisoformat(bf["black_friday"])
        before = [(friday - timedelta(days=7 * k)).isoformat() for k in range(1, 5)]
        for online, factor in ((True, 3.0), (False, 1.4)):
            base = statistics.mean(daily[(online, d)] for d in before)
            assert daily[(online, friday.isoformat())] > factor * base
            assert daily[(online, bf["cyber_monday"])] > factor * base * 0.9
        promo_codes = {line["promo_code"] for line in lines}
        assert bf["promo_code"] in promo_codes
    promo = {p["promo_code"]: p for p in ds.rows["promotions.csv"]}
    bf = promo[ds.truth["black_friday"][0]["promo_code"]]
    assert bf["category_code"] == "" and bf["sku"] == ""  # whole assortment


def test_promotions_lower_price_and_raise_volume(default_dataset: Dataset):
    ds = default_dataset
    price = {p["sku"]: Decimal(p["list_price"]) for p in ds.rows["products.csv"]}
    promo = {p["promo_code"]: p for p in ds.rows["promotions.csv"]}
    orders = order_index(ds)
    lines = ds.clean("order_lines.csv")
    for line in lines:
        expected = price[line["sku"]]
        if line["promo_code"]:
            expected *= 1 - Decimal(promo[line["promo_code"]]["discount_pct"])
        assert abs(Decimal(line["unit_price"]) - expected) <= Decimal("0.01")
    # Weekly hits: units/day of the SKU during the promotion vs the 4 weeks before.
    units = Counter()
    for line in lines:
        units[(line["sku"], orders[line["order_code"]]["ordered_at"][:10])] += int(line["quantity"])
    uplifts = []
    for p in promo.values():
        if not p["sku"]:
            continue
        s, e = date.fromisoformat(p["starts_on"]), date.fromisoformat(p["ends_on"])
        during = sum(units[(p["sku"], (s + timedelta(days=k)).isoformat())] for k in range(7)) / 7
        before = (
            sum(units[(p["sku"], (s - timedelta(days=k)).isoformat())] for k in range(1, 29)) / 28
        )
        # Skip hits whose comparison window is the start of the data or the Christmas peak.
        quiet = date(2024, 2, 1) <= s and e < date(2024, 11, 20) or date(2025, 2, 1) <= s
        if quiet and e < date(2025, 11, 20) and before > 0:
            uplifts.append(during / before)
    assert len(uplifts) >= 30
    assert statistics.median(uplifts) > 1.6


def _normal_stores(ds: Dataset) -> list[str]:
    flagged = {s["store_code"] for s in ds.truth["weak_stores"] + ds.truth["declining_stores"]}
    return [
        s["store_code"]
        for s in ds.rows["stores.csv"]
        if s["channel"] == "store" and s["store_code"] not in flagged
    ]


def test_declining_stores_drop_35_percent(default_dataset: Dataset):
    ds = default_dataset
    assert len(ds.truth["declining_stores"]) == 2
    normal = _normal_stores(ds)
    control = defaultdict(int)
    for code in normal:
        for week, n in weekly_orders(ds, code).items():
            control[week] += n
    for s in ds.truth["declining_stores"]:
        start = date.fromisoformat(s["from_date"])
        assert start.weekday() == 0
        weeks = weekly_orders(ds, s["store_code"])
        before = [w for w in weeks if start - timedelta(weeks=16) <= w < start]
        after = [w for w in weeks if start <= w < start + timedelta(weeks=16)]
        # Relative to the normal stores, so seasonality cancels out.
        ratio = (sum(weeks[w] for w in after) / sum(control[w] for w in after)) / (
            sum(weeks[w] for w in before) / sum(control[w] for w in before)
        )
        assert ratio == pytest.approx(1 - s["drop_pct"], abs=0.08)


def test_weak_stores_miss_plan_and_others_meet_it(default_dataset: Dataset):
    ds = default_dataset
    revenue = revenue_by(ds, lambda o: o["store_code"])
    plan = defaultdict(float)
    for b in ds.rows["budgets.csv"]:
        plan[b["store_code"]] += float(b["revenue_plan"])
    realization = {s: revenue[s] / plan[s] for s in plan}
    assert len(ds.truth["weak_stores"]) == 3
    for s in ds.truth["weak_stores"]:
        assert realization[s["store_code"]] < 0.9
    for s in [*_normal_stores(ds), "ONLINE"]:
        assert 0.9 <= realization[s] <= 1.1, s
    # The weak stores also have permanently lower traffic per m2 than the rest.
    size = {s["store_code"]: int(s["size_m2"] or 0) for s in ds.rows["stores.csv"]}
    orders = Counter(o["store_code"] for o in ds.clean("orders.csv"))
    weak_density = max(
        orders[s["store_code"]] / size[s["store_code"]] for s in ds.truth["weak_stores"]
    )
    normal_density = statistics.median(orders[s] / size[s] for s in _normal_stores(ds))
    assert weak_density < 0.8 * normal_density


def test_store_traffic_follows_size_and_purchasing_power(default_dataset: Dataset):
    ds = default_dataset
    ppi = {r["region_code"]: float(r["purchasing_power_index"]) for r in ds.rows["regions.csv"]}
    stores = {s["store_code"]: s for s in ds.rows["stores.csv"]}
    orders = Counter(o["store_code"] for o in ds.clean("orders.csv"))
    normal = [s for s in _normal_stores(ds)]
    x = [int(stores[s]["size_m2"]) * ppi[stores[s]["region_code"]] for s in normal]
    y = [orders[s] for s in normal]
    assert statistics.correlation(x, y) > 0.95


def test_margin_drop_category_purchase_costs(default_dataset: Dataset):
    ds = default_dataset
    drop = ds.truth["margin_drop"]
    a, b = date.fromisoformat(drop["purchases_from"]), date.fromisoformat(drop["purchases_to"])
    category = {p["sku"]: p["category_code"] for p in ds.rows["products.csv"]}
    costs = defaultdict(lambda: {"before": [], "during": []})
    for p in ds.rows["purchases.csv"]:
        d = date.fromisoformat(p["purchase_date"])
        if category[p["sku"]] != drop["category_code"]:
            continue
        if a - timedelta(days=90) <= d < a:
            costs[p["sku"]]["before"].append(float(p["unit_cost"]))
        elif a <= d <= b:
            costs[p["sku"]]["during"].append(float(p["unit_cost"]))
    ratios = [
        statistics.mean(c["during"]) / statistics.mean(c["before"])
        for c in costs.values()
        if c["during"] and c["before"]
    ]
    assert statistics.median(ratios) == pytest.approx(
        1 + drop["purchase_cost_increase_pct"], abs=0.03
    )


def test_pareto_assortment(default_dataset: Dataset):
    ds = default_dataset
    revenue = defaultdict(float)
    for line in ds.clean("order_lines.csv"):
        revenue[line["sku"]] += int(line["quantity"]) * float(line["unit_price"])
    share = top_share(list(revenue.values()))
    assert 0.70 <= share <= 0.85
    assert share == pytest.approx(ds.truth["pareto"]["top_20pct_sku_revenue_share"], abs=0.01)


def test_churn_promo_cohorts_leave_faster(default_dataset: Dataset):
    r90, r180 = retention(default_dataset, 90), retention(default_dataset, 180)
    assert r90[True] < r90[False] - 0.2
    assert r180[True] < r180[False] - 0.2
    assert r180[False] < r90[False]  # everyone churns over time


def test_anonymous_store_purchases(default_dataset: Dataset):
    store_orders = [o for o in default_dataset.clean("orders.csv") if o["store_code"] != "ONLINE"]
    anonymous = sum(not o["customer_code"] for o in store_orders) / len(store_orders)
    assert 0.35 <= anonymous <= 0.55


def test_online_share_and_basket(default_dataset: Dataset):
    ds = default_dataset
    orders = ds.clean("orders.csv")
    online = sum(o["store_code"] == "ONLINE" for o in orders) / len(orders)
    assert 0.2 <= online <= 0.35
    revenue = order_revenue(ds)
    assert 100 < statistics.mean(revenue.values()) < 600
