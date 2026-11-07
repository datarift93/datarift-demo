"""Measurements on a generated dataset, shared by the signal tests (and handy in a REPL)."""

from collections import defaultdict
from datetime import date, timedelta

from conftest import Dataset


def order_index(ds: Dataset) -> dict[str, dict[str, str]]:
    return {o["order_code"]: o for o in ds.clean("orders.csv")}


def order_revenue(ds: Dataset) -> dict[str, float]:
    revenue: dict[str, float] = defaultdict(float)
    for line in ds.clean("order_lines.csv"):
        revenue[line["order_code"]] += int(line["quantity"]) * float(line["unit_price"])
    return revenue


def order_day(o: dict[str, str]) -> date:
    return date.fromisoformat(o["ordered_at"][:10])


def revenue_by(ds: Dataset, key) -> dict:
    """Sum of line revenue grouped by key(order_row)."""
    orders = order_index(ds)
    out: dict = defaultdict(float)
    for code, value in order_revenue(ds).items():
        out[key(orders[code])] += value
    return out


def weekly_orders(ds: Dataset, store_code: str) -> dict[date, int]:
    weeks: dict[date, int] = defaultdict(int)
    for o in ds.clean("orders.csv"):
        if o["store_code"] == store_code:
            d = order_day(o)
            weeks[d - timedelta(days=d.weekday())] += 1
    return weeks


def top_share(values: list[float], fraction: float = 0.2) -> float:
    values = sorted(values, reverse=True)
    k = max(1, round(len(values) * fraction))
    return sum(values[:k]) / sum(values)


def retention(ds: Dataset, after_days: int) -> dict[bool, float]:
    """Share of customers registered in the range with an order >= after_days after sign-up,
    split by promo cohort (registered during a whole-assortment promotion)."""
    promos = [
        (date.fromisoformat(p["starts_on"]), date.fromisoformat(p["ends_on"]))
        for p in ds.rows["promotions.csv"]
        if not p["category_code"] and not p["sku"]
    ]
    start = date.fromisoformat(ds.truth["config"]["start_date"])
    end = date.fromisoformat(ds.truth["config"]["end_date"])
    last_order: dict[str, date] = {}
    for o in ds.clean("orders.csv"):
        if o["customer_code"]:
            d = order_day(o)
            if d > last_order.get(o["customer_code"], date.min):
                last_order[o["customer_code"]] = d
    kept: dict[bool, list[int]] = {True: [0, 0], False: [0, 0]}
    for c in ds.rows["customers.csv"]:
        reg = date.fromisoformat(c["registered_on"])
        # Only cohorts that can be observed for the full window.
        if reg < start or reg + timedelta(days=after_days) > end - timedelta(days=60):
            continue
        promo = any(a <= reg <= b for a, b in promos)
        kept[promo][1] += 1
        last = last_order.get(c["customer_code"])
        if last is not None and (last - reg).days >= after_days:
            kept[promo][0] += 1
    return {k: v[0] / v[1] for k, v in kept.items() if v[1]}
