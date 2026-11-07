"""Deterministic sales data generator for the "Wisła" retail chain.

Writes the CSV files from docs/data-model.md section 2 plus `_truth.json`, which lists every
planted signal (section 4) and every deliberately broken row.

Everything derives from `config.seed`: each part of the dataset draws from its own named
random stream (`_rng`), so changing one part does not reshuffle the others.

All money amounts (list_price, unit_price, unit_cost, revenue_plan) are net, excluding VAT.

Volumes are scaled down to fit the Supabase free tier (a store has ~8 orders a day), so the
signals are strong enough to see at weekly and monthly resolution, not daily.
"""

import csv
import json
import math
import zlib
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import numpy as np

from datarift_pipeline import calendar_pl
from datarift_pipeline.config import GeneratorConfig
from datarift_pipeline.nbp import Rate, RateTable
from datarift_pipeline.reference import (
    CATEGORIES,
    CITY_SLOTS,
    PRODUCT_LINES,
    REGIONS,
    SIZE_RANGE,
)

TZ = ZoneInfo("Europe/Warsaw")

# --- traffic -----------------------------------------------------------------------------
STORE_ORDERS_PER_DAY = 8.6  # average store at scale 1.0, before seasonality
ONLINE_ORDERS_PER_STORE = 2.8  # online orders per day per stationary store at scale 1.0
YEARLY_GROWTH = 0.04
DAILY_NOISE_SIGMA = 0.10  # lognormal store-day noise
MONTH_FACTOR = (0.8, 0.8, 0.95, 1.0, 1.0, 0.95, 0.95, 1.0, 0.95, 1.0, 1.1, 1.6)
# Mon..Sat for stores (Sunday is closed except trading Sundays); Mon..Sun online.
STORE_WEEKDAY = (0.9, 0.9, 0.95, 1.0, 1.2, 1.4)
TRADING_SUNDAY_FACTOR = 1.15
SHORT_DAY_FACTOR = 0.55
ONLINE_WEEKDAY = (1.25, 1.0, 0.95, 0.95, 0.9, 0.8, 1.3)
BF_STORE, BF_ONLINE = 1.8, 4.0  # Black Friday and Cyber Monday
BF_WEEKEND_STORE, BF_WEEKEND_ONLINE = 1.3, 1.6
ANNIVERSARY_STORE, ANNIVERSARY_ONLINE = 1.15, 1.2
ONLINE_CHRISTMAS = 0.6  # 24-26 Dec online

# --- planted store signals ---------------------------------------------------------------
WEAK_FACTOR = 0.6
WEAK_PLAN_FACTOR = 0.75  # planners expect weak stores to underperform, but not this much
DECLINE_FACTOR = 0.65  # -35% from the decline week on
PLAN_UPLIFT = 1.02
PLAN_NOISE_SIGMA = 0.03

# --- assortment and baskets --------------------------------------------------------------
ZIPF_EXPONENT = 0.95
PROMO_UPLIFT = 3.0  # product weight multiplier is 1 + PROMO_UPLIFT * discount
PROMO_EXTRA_QUANTITY = 2.0  # extra units per line: Poisson(PROMO_EXTRA_QUANTITY * discount)
EXTRA_LINES = {"store": 1.2, "online": 1.6}  # lines per order = 1 + Poisson(x), deduplicated
SINGLE_UNIT_PRICE = 1000_00  # items at or above this price (grosze) are bought one at a time
MARGIN_SIGMA = 0.06
MARGIN_DROP_PCT = 0.15
MARGIN_DROP_MONTHS = 2
COST_INFLATION = 0.03  # purchase costs per year
COST_NOISE_SIGMA = 0.015

# --- customers ---------------------------------------------------------------------------
STORE_IDENTIFIED_SHARE = 0.55  # store orders with a loyalty card; online orders always have one
EXISTING_CUSTOMER_SHARE = 0.35  # registered before start_date
REGISTERED_YEARS_BACK = 4
LIFETIME_DAYS = {"regular": 420.0, "promo": 100.0}  # mean of the exponential lifetime
PROMO_SIGNUP_BOOST = 5.0  # sign-up intensity on whole-assortment promotion days
ONLINE_AFFINITY_STORE_CUSTOMER = 0.08  # online order weight for store-home customers
FREQUENCY_SHAPE = 1.5  # gamma heterogeneity of purchase frequency

DIRTY_KINDS = ("unknown_sku", "zero_quantity", "negative_price", "duplicate", "date_out_of_range")

CATEGORY_THEMES = (
    # code prefix, name, category, month, day, length in days, discount
    ("ZIMA", "Wyprzedaż zimowa", "FASH", 1, 8, 21, 0.30),
    ("KOBIET", "Dzień Kobiet", "BEAUTY", 3, 1, 8, 0.20),
    ("ROWER", "Sezon rowerowy", "SPORT", 4, 5, 14, 0.15),
    ("OGROD", "Ogród na wiosnę", "HOME", 5, 4, 14, 0.20),
    ("DZIECKO", "Dzień Dziecka", "TOYS", 5, 25, 8, 0.25),
    ("LATO", "Wyprzedaż letnia", "FASH", 7, 1, 21, 0.30),
    ("SZKOLA", "Powrót do szkoły", "BOOKS", 8, 18, 21, 0.20),
    ("ELEKTRO", "Tydzień elektroniki", "ELEC", 10, 13, 7, 0.15),
    ("SMAKI", "Świąteczne smaki", "FOOD", 12, 1, 14, 0.10),
)
BF_DISCOUNT = 0.15
ANNIVERSARY_DISCOUNT = 0.15
HIT_DISCOUNTS = (0.20, 0.25, 0.30, 0.35)
HIT_EVERY_DAYS = 14


def _rng(seed: int, name: str) -> np.random.Generator:
    return np.random.default_rng([seed, zlib.crc32(name.encode())])


def _money(cents: int) -> str:
    sign = "-" if cents < 0 else ""
    cents = abs(int(cents))
    return f"{sign}{cents // 100}.{cents % 100:02d}"


def _month_start(d: date) -> date:
    return d.replace(day=1)


def _add_months(d: date, months: int) -> date:
    y, m = divmod(d.month - 1 + months, 12)
    return date(d.year + y, m + 1, 1)


@dataclass
class Calendar:
    start: date
    dates: list[date]
    weekday: np.ndarray
    month: np.ndarray  # 0..11
    holidays: dict[date, str]
    trading_sundays: list[date]
    short_days: list[date]
    black_fridays: list[date]

    @property
    def n(self) -> int:
        return len(self.dates)

    def index(self, d: date) -> int:
        return (d - self.start).days

    def mask(self, days) -> np.ndarray:
        m = np.zeros(self.n, dtype=bool)
        for d in days:
            if 0 <= self.index(d) < self.n:
                m[self.index(d)] = True
        return m


def _calendar(config: GeneratorConfig) -> Calendar:
    dates = [config.start_date + timedelta(days=i) for i in range(config.days)]
    years = range(config.start_date.year, config.end_date.year + 1)
    in_range = lambda d: config.start_date <= d <= config.end_date  # noqa: E731
    holidays = {d: n for y in years for d, n in calendar_pl.public_holidays(y).items()}
    return Calendar(
        start=config.start_date,
        dates=dates,
        weekday=np.array([d.weekday() for d in dates]),
        month=np.array([d.month - 1 for d in dates]),
        holidays={d: n for d, n in sorted(holidays.items()) if in_range(d)},
        trading_sundays=[d for y in years for d in calendar_pl.trading_sundays(y) if in_range(d)],
        short_days=[d for y in years for d in calendar_pl.short_trading_days(y) if in_range(d)],
        black_fridays=[
            calendar_pl.black_friday(y)
            for y in years
            if in_range(calendar_pl.black_friday(y)) and in_range(calendar_pl.cyber_monday(y))
        ],
    )


# ----------------------------------------------------------------------------------------
# dimensions
# ----------------------------------------------------------------------------------------


@dataclass
class Stores:
    codes: list[str]
    names: list[str]
    city: list[str | None]
    region: list[str | None]
    size: list[int | None]
    opened: list[date]
    is_online: np.ndarray  # bool per store
    base: np.ndarray  # orders per day before seasonality
    weak: list[int]
    declining: list[tuple[int, date]]

    @property
    def n(self) -> int:
        return len(self.codes)


def _stores(config: GeneratorConfig, cal: Calendar) -> Stores:
    rng = _rng(config.seed, "stores")
    ppi = {r.code: r.purchasing_power_index for r in REGIONS}
    numbers: dict[str, int] = {}
    codes, names, cities, regions, sizes, opened = [], [], [], [], [], []
    for i in range(config.store_count):
        city = CITY_SLOTS[i % len(CITY_SLOTS)]
        numbers[city.code] = numbers.get(city.code, 0) + 1
        n = numbers[city.code]
        codes.append(f"{city.code}-{n:02d}")
        names.append(f"{city.name} {n}")
        cities.append(city.name)
        regions.append(city.region_code)
        lo, hi = SIZE_RANGE[city.tier]
        sizes.append(int(rng.integers(lo, hi + 1)) // 10 * 10)
        first, last = date(2008, 1, 1), config.start_date - timedelta(days=365)
        opened.append(first + timedelta(days=int(rng.integers(0, (last - first).days + 1))))
    traffic = np.array([s * ppi[r] for s, r in zip(sizes, regions, strict=True)])
    base = STORE_ORDERS_PER_DAY * config.scale * traffic / traffic.mean()
    is_online = [False] * config.store_count
    if config.online_store:
        codes.append("ONLINE")
        names.append("Sklep internetowy")
        cities.append(None)
        regions.append(None)
        sizes.append(None)
        opened.append(min(date(2019, 3, 1), config.start_date - timedelta(days=365)))
        is_online.append(True)
        base = np.append(base, ONLINE_ORDERS_PER_STORE * config.scale * config.store_count)

    # Declining stores come from the larger half (more orders, so the drop stands out of the
    # Poisson noise); weak stores from the rest.
    by_size = np.argsort(-base[: config.store_count], kind="stable")
    large = rng.permutation(by_size[: max(config.store_count // 2, config.declining_store_count)])
    declining_idx = large[: config.declining_store_count]
    others = rng.permutation(np.setdiff1d(np.arange(config.store_count), declining_idx))
    weak = sorted(int(i) for i in others[: config.weak_store_count])
    declining = []
    for i in sorted(int(i) for i in declining_idx):
        # Somewhere in the second half of the range, so there is a year of history before it.
        day = int(rng.integers(int(cal.n * 0.55), int(cal.n * 0.85)))
        week = cal.dates[day] - timedelta(days=cal.dates[day].weekday())
        declining.append((i, week))
    return Stores(
        codes, names, cities, regions, sizes, opened, np.array(is_online), base, weak, declining
    )


@dataclass
class Products:
    skus: list[str]
    names: list[str]
    category: np.ndarray  # index into CATEGORIES
    list_cents: np.ndarray
    eur: np.ndarray  # bool
    popularity: np.ndarray  # Zipf weight
    cost_pln: np.ndarray  # base purchase cost in PLN (float)

    @property
    def n(self) -> int:
        return len(self.skus)


def _round_price(value: float) -> int:
    """Shelf price in grosze ending in ,99 (or ,49 under 20 zł)."""
    if value < 20:
        return max(int(math.floor(value)), 1) * 100 + (49 if value % 1 < 0.5 else 99)
    return int(round(value)) * 100 - 1


def _products(config: GeneratorConfig) -> Products:
    rng = _rng(config.seed, "products")
    shares = np.array([c.product_share for c in CATEGORIES])
    counts = np.floor(shares * config.product_count).astype(int)
    for i in np.argsort(-(shares * config.product_count - counts))[
        : config.product_count - counts.sum()
    ]:
        counts[i] += 1

    skus, names, cats, prices, eur, costs = [], [], [], [], [], []
    for ci, (cat, count) in enumerate(zip(CATEGORIES, counts, strict=True)):
        combos = [
            (item, brand, line)
            for item in cat.items
            for brand in cat.brands
            for line in PRODUCT_LINES
        ]
        chosen = rng.choice(len(combos), size=count, replace=False)
        n_eur = round(cat.eur_share * count)
        eur_flags = np.zeros(count, dtype=bool)
        eur_flags[rng.choice(count, size=n_eur, replace=False)] = True
        for k, combo_i in enumerate(chosen):
            (base, lo, hi), brand, line = combos[combo_i]
            price = _round_price(math.exp(rng.uniform(math.log(lo), math.log(hi))))
            margin = cat.margin * math.exp(rng.normal(0, MARGIN_SIGMA))
            skus.append(f"{cat.code}-{k + 1:04d}")
            names.append(f"{base} {brand} {line}")
            cats.append(ci)
            prices.append(price)
            eur.append(bool(eur_flags[k]))
            costs.append(price / 100 * (1 - margin))
    ranks = rng.permutation(len(skus)) + 1
    return Products(
        skus=skus,
        names=names,
        category=np.array(cats),
        list_cents=np.array(prices, dtype=np.int64),
        eur=np.array(eur),
        popularity=1.0 / ranks**ZIPF_EXPONENT,
        cost_pln=np.array(costs),
    )


@dataclass
class Promotion:
    code: str
    name: str
    starts_on: date
    ends_on: date
    category: int | None
    sku: int | None
    discount: float

    @property
    def whole_assortment(self) -> bool:
        return self.category is None and self.sku is None


def _promotions(config: GeneratorConfig, cal: Calendar, products: Products) -> list[Promotion]:
    rng = _rng(config.seed, "promotions")
    cat_index = {c.code: i for i, c in enumerate(CATEGORIES)}
    promos: list[Promotion] = []
    for year in range(config.start_date.year, config.end_date.year + 1):
        for prefix, name, cat, month, day, length, discount in CATEGORY_THEMES:
            start = date(year, month, day) + timedelta(days=int(rng.integers(0, 4)))
            promos.append(
                Promotion(
                    f"{prefix}-{year}",
                    f"{name} {year}",
                    start,
                    start + timedelta(days=length - 1),
                    cat_index[cat],
                    None,
                    discount,
                )
            )
        sept = date(year, 9, 8)
        anniversary = sept + timedelta(days=(7 - sept.weekday()) % 7)
        promos.append(
            Promotion(
                f"URO-{year}",
                f"Urodziny Wisły {year}",
                anniversary,
                anniversary + timedelta(days=6),
                None,
                None,
                ANNIVERSARY_DISCOUNT,
            )
        )
        bf = calendar_pl.black_friday(year)
        promos.append(
            Promotion(
                f"BF-{year}",
                f"Black Friday {year}",
                bf,
                calendar_pl.cyber_monday(year),
                None,
                None,
                BF_DISCOUNT,
            )
        )
        # "Hit tygodnia": one popular product at a deep discount every two weeks.
        top = np.argsort(-products.popularity)[: max(products.n // 4, 1)]
        first_monday = date(year, 1, 1) + timedelta(days=(7 - date(year, 1, 1).weekday()) % 7)
        for k, start in enumerate(
            first_monday + timedelta(days=d) for d in range(0, 358, HIT_EVERY_DAYS)
        ):
            p = int(rng.choice(top))
            margin = 1 - products.cost_pln[p] / (products.list_cents[p] / 100)
            options = [d for d in HIT_DISCOUNTS if d <= max(margin, HIT_DISCOUNTS[0])]
            promos.append(
                Promotion(
                    f"HIT-{year}-{k + 1:02d}",
                    f"Hit tygodnia {year}/{k + 1:02d}",
                    start,
                    start + timedelta(days=6),
                    None,
                    p,
                    float(rng.choice(options)),
                )
            )
    return [p for p in promos if p.starts_on >= config.start_date and p.ends_on <= config.end_date]


def _promo_matrix(cal: Calendar, products: Products, promos: list[Promotion]):
    """Best discount and its promotion index for every (day, product); -1 = no promotion."""
    discount = np.zeros((cal.n, products.n))
    index = np.full((cal.n, products.n), -1, dtype=np.int32)
    for i, p in enumerate(promos):
        d0, d1 = cal.index(p.starts_on), cal.index(p.ends_on) + 1
        if p.sku is not None:
            cols = np.zeros(products.n, dtype=bool)
            cols[p.sku] = True
        elif p.category is not None:
            cols = products.category == p.category
        else:
            cols = np.ones(products.n, dtype=bool)
        block = discount[d0:d1][:, cols]
        better = p.discount > block
        block[better] = p.discount
        discount[d0:d1, cols] = block
        idx_block = index[d0:d1][:, cols]
        idx_block[better] = i
        index[d0:d1, cols] = idx_block
    return discount, index


# ----------------------------------------------------------------------------------------
# traffic
# ----------------------------------------------------------------------------------------


def _traffic(config: GeneratorConfig, cal: Calendar, stores: Stores, promos: list[Promotion]):
    """Expected orders per (store, day): (planned, actual). Planned is what budgets assume."""
    t_years = np.arange(cal.n) / 365.0
    common = (1 + YEARLY_GROWTH * t_years) * np.array(MONTH_FACTOR)[cal.month]
    dom = np.array([d.day for d in cal.dates])
    dec = cal.month == 11
    ramp = np.ones(cal.n)
    ramp[dec & (dom <= 23)] = 0.85 + 0.5 * (dom[dec & (dom <= 23)] - 1) / 22
    ramp[dec & (dom == 24)] = 0.7
    ramp[dec & (dom >= 27)] = 0.75
    common = common * ramp

    holiday = cal.mask(cal.holidays)
    trading_sunday = cal.mask(cal.trading_sundays)
    short = cal.mask(cal.short_days)
    sunday = cal.weekday == 6
    store_day = np.where(sunday, TRADING_SUNDAY_FACTOR, np.array(STORE_WEEKDAY + (0,))[cal.weekday])
    store_day = store_day * ~holiday * (~sunday | trading_sunday)
    store_day = store_day * np.where(short, SHORT_DAY_FACTOR, 1.0)
    online_day = np.array(ONLINE_WEEKDAY)[cal.weekday]
    christmas = cal.mask(d for d in cal.dates if d.month == 12 and 24 <= d.day <= 26) | cal.mask(
        calendar_pl.easter_sunday(y) for y in {d.year for d in cal.dates}
    )
    online_day = online_day * np.where(christmas, ONLINE_CHRISTMAS, 1.0)

    bf_days = cal.mask([*cal.black_fridays, *(bf + timedelta(days=3) for bf in cal.black_fridays)])
    bf_weekend = cal.mask(bf + timedelta(days=k) for bf in cal.black_fridays for k in (1, 2))
    anniversary = np.zeros(cal.n, dtype=bool)
    for p in promos:
        if p.code.startswith("URO-"):
            anniversary[cal.index(p.starts_on) : cal.index(p.ends_on) + 1] = True
    store_day = store_day * np.select(
        [bf_days, bf_weekend, anniversary], [BF_STORE, BF_WEEKEND_STORE, ANNIVERSARY_STORE], 1.0
    )
    online_day = online_day * np.select(
        [bf_days, bf_weekend, anniversary], [BF_ONLINE, BF_WEEKEND_ONLINE, ANNIVERSARY_ONLINE], 1.0
    )

    channel_day = np.where(stores.is_online[:, None], online_day[None, :], store_day[None, :])
    planned = stores.base[:, None] * common[None, :] * channel_day
    actual = planned.copy()
    for s in stores.weak:
        planned[s] *= WEAK_PLAN_FACTOR
        actual[s] *= WEAK_FACTOR
    for s, week in stores.declining:
        actual[s, cal.index(week) :] *= DECLINE_FACTOR
    rng = _rng(config.seed, "traffic")
    actual = actual * rng.lognormal(0, DAILY_NOISE_SIGMA, size=actual.shape)
    return planned, actual


# ----------------------------------------------------------------------------------------
# orders
# ----------------------------------------------------------------------------------------

# Relative order intensity per hour.
STORE_HOURS = {
    "weekday": (8, (0.4, 0.6, 0.8, 0.9, 1.0, 1.0, 0.95, 1.0, 1.2, 1.35, 1.3, 1.0, 0.6)),
    "saturday": (8, (0.5, 0.9, 1.2, 1.4, 1.45, 1.35, 1.2, 1.0, 0.9, 0.8, 0.6, 0.4, 0.2)),
    "sunday": (10, (0.8, 1.2, 1.4, 1.4, 1.3, 1.2, 1.0, 0.8, 0.5)),
    "short": (8, (0.6, 1.0, 1.3, 1.4, 1.2, 0.9)),
}
ONLINE_HOURS = (
    0.3, 0.2, 0.1, 0.1, 0.1, 0.2, 0.4, 0.7, 0.9, 1.0, 1.0, 1.0,
    1.1, 1.1, 1.0, 1.0, 1.1, 1.2, 1.4, 1.7, 2.0, 2.1, 1.6, 0.8,
)  # fmt: skip
ONLINE_EVENING_BOOST = 1.6  # 19:00-22:59 on Sundays and Mondays


def _order_seconds(rng, cal: Calendar, day: np.ndarray, online: np.ndarray) -> np.ndarray:
    short = cal.mask(cal.short_days)
    wd = cal.weekday[day]
    profile = np.where(
        online,
        np.where((wd == 0) | (wd == 6), "online_evening", "online"),
        np.where(
            short[day],
            "short",
            np.where(wd == 5, "saturday", np.where(wd == 6, "sunday", "weekday")),
        ),
    )
    hours = np.zeros(len(day), dtype=np.int64)
    profiles = {name: (first, w) for name, (first, w) in STORE_HOURS.items()}
    evening = np.array(ONLINE_HOURS)
    evening[19:23] *= ONLINE_EVENING_BOOST
    profiles["online"] = (0, ONLINE_HOURS)
    profiles["online_evening"] = (0, tuple(evening))
    for name in sorted(profiles):
        first, weights = profiles[name]
        sel = np.nonzero(profile == name)[0]
        w = np.array(weights) / sum(weights)
        hours[sel] = first + rng.choice(len(w), size=len(sel), p=w)
    return hours * 3600 + rng.integers(0, 3600, size=len(day))


@dataclass
class Orders:
    day: np.ndarray
    seconds: np.ndarray
    store: np.ndarray
    customer: np.ndarray  # -1 = anonymous

    @property
    def n(self) -> int:
        return len(self.day)


@dataclass
class Customers:
    home: np.ndarray  # store index (online store for online customers)
    region: list[str]
    reg_day: np.ndarray  # day index relative to start_date (negative = before the range)
    end_day: np.ndarray  # last active day index
    promo_cohort: np.ndarray  # bool
    frequency: np.ndarray

    @property
    def n(self) -> int:
        return len(self.home)


def _customers(
    config: GeneratorConfig,
    cal: Calendar,
    stores: Stores,
    planned: np.ndarray,
    promos: list[Promotion],
) -> Customers:
    rng = _rng(config.seed, "customers")
    n = config.customer_count
    identified = planned.sum(axis=1) * np.where(stores.is_online, 1.0, STORE_IDENTIFIED_SHARE)
    home = rng.choice(stores.n, size=n, p=identified / identified.sum())

    weights = np.array([r.population_m * r.purchasing_power_index for r in REGIONS])
    online_regions = rng.choice(len(REGIONS), size=n, p=weights / weights.sum())
    region = [
        stores.region[h] or REGIONS[online_regions[i]].code for i, h in enumerate(home.tolist())
    ]

    boost = np.ones(cal.n)
    for p in promos:
        if p.whole_assortment:
            boost[cal.index(p.starts_on) : cal.index(p.ends_on) + 1] = PROMO_SIGNUP_BOOST
    existing = rng.random(n) < EXISTING_CUSTOMER_SHARE
    reg_day = np.zeros(n, dtype=np.int64)
    for h in range(stores.n):
        sel = np.nonzero((home == h) & ~existing)[0]
        w = planned[h] * boost
        reg_day[sel] = rng.choice(cal.n, size=len(sel), p=w / w.sum())
        old = np.nonzero((home == h) & existing)[0]
        first = max((stores.opened[h] - cal.start).days, -365 * REGISTERED_YEARS_BACK)
        reg_day[old] = rng.integers(first, 0, size=len(old))
    promo_cohort = (~existing) & (boost[np.clip(reg_day, 0, cal.n - 1)] > 1)
    mean_life = np.where(promo_cohort, LIFETIME_DAYS["promo"], LIFETIME_DAYS["regular"])
    life = rng.exponential(mean_life)
    # Memoryless lifetime: existing customers get a fresh lifetime from start_date.
    end_day = np.where(existing, 0, reg_day) + np.floor(life).astype(np.int64)
    frequency = rng.gamma(FREQUENCY_SHAPE, 1 / FREQUENCY_SHAPE, size=n)
    return Customers(home, region, reg_day, end_day, promo_cohort, frequency)


def _orders(config, cal, stores, actual, customers) -> Orders:
    rng = _rng(config.seed, "orders")
    counts = rng.poisson(actual)  # (store, day)
    flat = counts.T.ravel()  # day-major
    day = np.repeat(np.repeat(np.arange(cal.n), stores.n), flat)
    store = np.repeat(np.tile(np.arange(stores.n), cal.n), flat)
    online = stores.is_online[store]
    seconds = _order_seconds(rng, cal, day, online)
    order = np.lexsort((store, seconds, day))
    day, store, seconds, online = day[order], store[order], seconds[order], online[order]

    identified = online | (rng.random(len(day)) < STORE_IDENTIFIED_SHARE)
    customer = np.full(len(day), -1, dtype=np.int64)
    by_home = [np.nonzero(customers.home == h)[0] for h in range(stores.n)]
    online_weight = customers.frequency * np.where(
        stores.is_online[customers.home], 1.0, ONLINE_AFFINITY_STORE_CUSTOMER
    )
    ident_idx = np.nonzero(identified)[0]
    key = day[ident_idx] * stores.n + store[ident_idx]
    bounds = np.flatnonzero(np.diff(key)) + 1
    for group in np.split(ident_idx, bounds):
        if len(group) == 0:
            continue
        d, h = int(day[group[0]]), int(store[group[0]])
        # New sign-ups place their first order on the day they register.
        mine = by_home[h]
        new = mine[customers.reg_day[mine] == d]
        new = new[rng.permutation(len(new))][: len(group)]
        customer[group[: len(new)]] = new
        rest = group[len(new) :]
        if len(rest) == 0:
            continue
        if stores.is_online[h]:
            pool = np.nonzero((customers.reg_day <= d) & (customers.end_day >= d))[0]
            w = online_weight[pool]
        else:
            pool = mine[(customers.reg_day[mine] <= d) & (customers.end_day[mine] >= d)]
            w = customers.frequency[pool]
        if len(pool) == 0:
            continue  # nobody active: stays anonymous (stores only; online always has a pool)
        customer[rest] = rng.choice(pool, size=len(rest), p=w / w.sum())
    if stores.is_online.any():
        assert (customer[online] >= 0).all(), "online orders need a customer"
    return Orders(day, seconds, store, customer)


@dataclass
class Lines:
    order: np.ndarray
    line_no: np.ndarray
    product: np.ndarray
    quantity: np.ndarray
    price_cents: np.ndarray
    promo: np.ndarray  # -1 = none


def _lines(config, cal, stores, products, orders, discount, promo_index) -> Lines:
    rng = _rng(config.seed, "lines")
    online = stores.is_online[orders.store]
    n_lines = 1 + rng.poisson(np.where(online, EXTRA_LINES["online"], EXTRA_LINES["store"]))
    order = np.repeat(np.arange(orders.n), n_lines)
    day = orders.day[order]
    channel = online[order].astype(np.int64)

    season = np.array([c.season for c in CATEGORIES]).T  # (month, category)
    affinity = np.array([[1.0] * len(CATEGORIES), [c.online_affinity for c in CATEGORIES]])
    product = np.zeros(len(order), dtype=np.int64)
    key = channel * cal.n + day
    sort = np.argsort(key, kind="stable")
    bounds = np.flatnonzero(np.diff(key[sort])) + 1
    for group in np.split(sort, bounds):
        c, d = int(channel[group[0]]), int(day[group[0]])
        w = (
            products.popularity
            * season[cal.month[d], products.category]
            * affinity[c, products.category]
            * (1 + PROMO_UPLIFT * discount[d])
        )
        product[group] = rng.choice(products.n, size=len(group), p=w / w.sum())

    # One line per product in an order.
    _, first = np.unique(order * products.n + product, return_index=True)
    keep = np.sort(first)
    order, day, product = order[keep], day[keep], product[keep]
    per_order = np.bincount(order, minlength=orders.n)
    starts = np.concatenate(([0], np.cumsum(per_order)[:-1]))
    line_no = np.arange(len(order)) - np.repeat(starts, per_order) + 1

    disc = discount[day, product]
    extra = np.array([c.extra_quantity for c in CATEGORIES])[products.category[product]]
    quantity = 1 + rng.poisson(extra + PROMO_EXTRA_QUANTITY * disc)
    quantity[products.list_cents[product] >= SINGLE_UNIT_PRICE] = 1
    price = np.round(products.list_cents[product] * (1 - disc)).astype(np.int64)
    return Lines(order, line_no, product, quantity, price, promo_index[day, product])


# ----------------------------------------------------------------------------------------
# purchases and budgets
# ----------------------------------------------------------------------------------------


@dataclass
class Purchases:
    product: np.ndarray
    day: np.ndarray  # relative to start_date (negative before)
    quantity: np.ndarray
    cost_cents: np.ndarray  # in purchase currency


def _purchases(config, cal, products, orders, lines, fx: RateTable, margin_drop) -> Purchases:
    rng = _rng(config.seed, "purchases")
    lookback = config.purchase_lookback_days
    daily = np.zeros((products.n, cal.n))
    np.add.at(daily, (lines.product, orders.day[lines.order]), lines.quantity)
    mean_daily = daily.mean(axis=1)
    # Pre-range demand: the product's average.
    demand = np.concatenate([np.repeat(mean_daily[:, None], lookback, axis=1), daily], axis=1)
    cum = np.concatenate([np.zeros((products.n, 1)), np.cumsum(demand, axis=1)], axis=1)
    total_days = lookback + cal.n

    median = np.median(mean_daily[mean_daily > 0]) if (mean_daily > 0).any() else 1.0
    interval = np.clip(np.round(14 * np.sqrt(median / np.maximum(mean_daily, 1e-6))), 7, 42).astype(
        int
    )
    ref_rate = fx.mean_rate(config.purchases_start, config.end_date)
    drop_cat, drop_from, drop_to = margin_drop
    drop_from_i, drop_to_i = (drop_from - cal.start).days, (drop_to - cal.start).days

    rows_p, rows_d, rows_q, rows_c = [], [], [], []
    for p in range(products.n):
        t = int(rng.integers(0, interval[p]))
        while t < total_days:
            nxt = min(t + int(interval[p]), total_days)
            rel = t - lookback
            dt = cal.start + timedelta(days=rel)
            # Suppliers deliver on business days: move weekends to the Friday before.
            if dt.weekday() >= 5:
                rel -= dt.weekday() - 4
            need = cum[p, nxt] - cum[p, t]
            qty = max(1, math.ceil(need * rng.uniform(1.0, 1.15)))
            cost = products.cost_pln[p] * (1 + COST_INFLATION * rel / 365.0)
            cost *= math.exp(rng.normal(0, COST_NOISE_SIGMA))
            if products.category[p] == drop_cat and drop_from_i <= rel <= drop_to_i:
                cost *= 1 + MARGIN_DROP_PCT
            if products.eur[p]:
                cost /= ref_rate  # EUR price list fixed at the average rate
            rows_p.append(p)
            rows_d.append(rel)
            rows_q.append(qty)
            rows_c.append(round(cost * 100))
            t = nxt + int(rng.integers(-2, 3)) if nxt < total_days else nxt
    order = np.lexsort((np.array(rows_p), np.array(rows_d)))
    return Purchases(
        np.array(rows_p)[order],
        np.array(rows_d)[order],
        np.array(rows_q)[order],
        np.array(rows_c, dtype=np.int64)[order],
    )


def _budgets(config, cal, stores, planned, orders, lines):
    """Revenue plan per store and month: planned traffic x average order value of the channel."""
    rng = _rng(config.seed, "budgets")
    revenue = np.bincount(
        lines.order, weights=lines.quantity * lines.price_cents, minlength=orders.n
    )
    online = stores.is_online[orders.store]
    aov = {ch: revenue[online == ch].sum() / max((online == ch).sum(), 1) for ch in (False, True)}
    months = sorted({_month_start(d) for d in cal.dates})
    month_of_day = np.array([months.index(_month_start(d)) for d in cal.dates])
    rows = []
    for s in range(stores.n):
        per_month = np.bincount(month_of_day, weights=planned[s], minlength=len(months))
        noise = rng.normal(0, PLAN_NOISE_SIGMA, size=len(months))
        for m, month in enumerate(months):
            plan = per_month[m] * aov[bool(stores.is_online[s])] * PLAN_UPLIFT * (1 + noise[m])
            rows.append((s, month, int(round(plan / 100_00)) * 100_00))  # whole hundreds of zł
    return rows


# ----------------------------------------------------------------------------------------
# output
# ----------------------------------------------------------------------------------------


def _timestamps(cal: Calendar, day: np.ndarray, seconds: np.ndarray) -> list[str]:
    """ISO 8601 local Polish time; times skipped by the spring DST change move one hour on."""
    offsets: dict[tuple[int, int], tuple[int, str]] = {}
    out = []
    for d, s in zip(day.tolist(), seconds.tolist(), strict=True):
        h = s // 3600
        key = (d, h)
        if key not in offsets:
            base = datetime.combine(cal.start + timedelta(days=d), datetime.min.time())
            local = base.replace(hour=h, tzinfo=TZ)
            back = local.astimezone(ZoneInfo("UTC")).astimezone(TZ)
            shift = 3600 if back.hour != h else 0
            off = back.utcoffset()
            assert off is not None
            hours = int(off.total_seconds()) // 3600
            offsets[key] = (shift, f"+{hours:02d}:00")
        shift, off = offsets[key]
        s += shift
        dt = cal.start + timedelta(days=d)
        out.append(f"{dt.isoformat()}T{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}{off}")
    return out


def _write(path: Path, header: tuple[str, ...], rows) -> int:
    count = 0
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f, lineterminator="\n")
        writer.writerow(header)
        for row in rows:
            writer.writerow(row)
            count += 1
    return count


def _dirty_rows(config, cal, stores, products, orders, lines):
    """Broken rows added to the clean data: (extra order lines, out-of-range orders)."""
    rng = _rng(config.seed, "dirty")
    total = round(config.dirty_row_rate * (orders.n + len(lines.order)))
    per_kind = {k: total // len(DIRTY_KINDS) for k in DIRTY_KINDS}
    for k in DIRTY_KINDS[: total % len(DIRTY_KINDS)]:
        per_kind[k] += 1

    line_kinds = [k for k in DIRTY_KINDS if k != "date_out_of_range"]
    n_line_dirty = sum(per_kind[k] for k in line_kinds)
    templates = rng.choice(len(lines.order), size=n_line_dirty, replace=False)
    max_line = np.maximum.reduceat(lines.line_no, np.flatnonzero(np.r_[True, np.diff(lines.order)]))
    max_line_by_order = np.zeros(orders.n, dtype=np.int64)
    max_line_by_order[np.unique(lines.order)] = max_line
    extra = []  # (order, line_no, sku string, quantity, price_cents, promo, kind, after_template)
    pos = 0
    for kind in line_kinds:
        for t in templates[pos : pos + per_kind[kind]]:
            o = int(lines.order[t])
            sku = products.skus[lines.product[t]]
            qty, price = int(lines.quantity[t]), int(lines.price_cents[t])
            promo = int(lines.promo[t])
            if kind == "duplicate":
                extra.append((o, int(lines.line_no[t]), sku, qty, price, promo, kind, True))
                continue
            max_line_by_order[o] += 1
            line_no = int(max_line_by_order[o])
            if kind == "unknown_sku":
                cat = CATEGORIES[products.category[lines.product[t]]].code
                sku = f"{cat}-{int(rng.integers(9000, 10000)):04d}"
            elif kind == "zero_quantity":
                qty = 0
            elif kind == "negative_price":
                price = -price
            extra.append((o, line_no, sku, qty, price, promo, kind, False))
        pos += per_kind[kind]

    physical = np.nonzero(~stores.is_online)[0]
    bad_orders = []
    for _ in range(per_kind["date_out_of_range"]):
        before = rng.random() < 0.5
        offset = int(rng.integers(1, 61))
        d = -offset if before else cal.n - 1 + offset
        bad_orders.append(
            (
                d,
                int(rng.integers(9 * 3600, 20 * 3600)),
                int(rng.choice(physical)),
                float(rng.uniform(0, orders.n)),
            )
        )
    return extra, bad_orders


def _margin_drop(config: GeneratorConfig, cal: Calendar):
    rng = _rng(config.seed, "margin_drop")
    cat = int(rng.integers(0, len(CATEGORIES)))
    months = sorted({_month_start(d) for d in cal.dates})
    lo = int(len(months) * 0.6)
    hi = max(lo + 1, len(months) - MARGIN_DROP_MONTHS - 1)
    start = months[int(rng.integers(lo, hi))]
    end = _add_months(start, MARGIN_DROP_MONTHS) - timedelta(days=1)
    return cat, start, end


def generate(config: GeneratorConfig, rates: list[Rate], out: Path) -> dict[str, int]:
    fx = RateTable(rates)
    if not fx.covers(config.purchases_start, config.end_date):
        raise ValueError(
            f"NBP rates {fx.first_date}..{fx.last_date} do not cover purchases "
            f"{config.purchases_start}..{config.end_date}: run fetch-rates"
        )
    out.mkdir(parents=True, exist_ok=True)
    cal = _calendar(config)
    stores = _stores(config, cal)
    products = _products(config)
    promos = _promotions(config, cal, products)
    discount, promo_index = _promo_matrix(cal, products, promos)
    planned, actual = _traffic(config, cal, stores, promos)
    customers = _customers(config, cal, stores, planned, promos)
    orders = _orders(config, cal, stores, actual, customers)
    lines = _lines(config, cal, stores, products, orders, discount, promo_index)
    margin_drop = _margin_drop(config, cal)
    purchases = _purchases(config, cal, products, orders, lines, fx, margin_drop)
    budgets = _budgets(config, cal, stores, planned, orders, lines)
    extra_lines, bad_orders = _dirty_rows(config, cal, stores, products, orders, lines)

    # Customer codes in registration order.
    cust_order = np.lexsort((np.arange(customers.n), customers.reg_day))
    cust_code = np.empty(customers.n, dtype=object)
    cust_code[cust_order] = [f"C{i + 1:06d}" for i in range(customers.n)]
    order_codes = [f"O{i + 1:07d}" for i in range(orders.n + len(bad_orders))]

    counts: dict[str, int] = {}
    counts["regions.csv"] = _write(
        out / "regions.csv",
        ("region_code", "name", "purchasing_power_index"),
        ((r.code, r.name, f"{r.purchasing_power_index:.2f}") for r in REGIONS),
    )
    counts["stores.csv"] = _write(
        out / "stores.csv",
        ("store_code", "name", "channel", "city", "region_code", "size_m2", "opened_on"),
        (
            (
                stores.codes[s],
                stores.names[s],
                "online" if stores.is_online[s] else "store",
                stores.city[s],
                stores.region[s],
                stores.size[s],
                stores.opened[s].isoformat(),
            )
            for s in range(stores.n)
        ),
    )
    counts["categories.csv"] = _write(
        out / "categories.csv", ("category_code", "name"), ((c.code, c.name) for c in CATEGORIES)
    )
    counts["products.csv"] = _write(
        out / "products.csv",
        ("sku", "name", "category_code", "list_price", "purchase_currency"),
        (
            (
                products.skus[p],
                products.names[p],
                CATEGORIES[products.category[p]].code,
                _money(products.list_cents[p]),
                "EUR" if products.eur[p] else "PLN",
            )
            for p in range(products.n)
        ),
    )
    counts["customers.csv"] = _write(
        out / "customers.csv",
        ("customer_code", "region_code", "registered_on"),
        (
            (
                cust_code[c],
                customers.region[c],
                (cal.start + timedelta(days=int(customers.reg_day[c]))).isoformat(),
            )
            for c in cust_order.tolist()
        ),
    )
    counts["promotions.csv"] = _write(
        out / "promotions.csv",
        ("promo_code", "name", "starts_on", "ends_on", "category_code", "sku", "discount_pct"),
        (
            (
                p.code,
                p.name,
                p.starts_on.isoformat(),
                p.ends_on.isoformat(),
                CATEGORIES[p.category].code if p.category is not None else None,
                products.skus[p.sku] if p.sku is not None else None,
                f"{p.discount:.2f}",
            )
            for p in promos
        ),
    )
    counts["purchases.csv"] = _write(
        out / "purchases.csv",
        ("purchase_code", "sku", "purchase_date", "quantity", "unit_cost", "currency"),
        (
            (
                f"P{i + 1:06d}",
                products.skus[p],
                (cal.start + timedelta(days=d)).isoformat(),
                q,
                _money(c),
                "EUR" if products.eur[p] else "PLN",
            )
            for i, (p, d, q, c) in enumerate(
                zip(
                    purchases.product.tolist(),
                    purchases.day.tolist(),
                    purchases.quantity.tolist(),
                    purchases.cost_cents.tolist(),
                    strict=True,
                )
            )
        ),
    )

    # orders.csv: clean orders in time order, broken ones at random positions.
    stamps = _timestamps(cal, orders.day, orders.seconds)
    order_rows = [
        (order_codes[i], stores.codes[s], cust_code[c] if c >= 0 else None, stamps[i], float(i))
        for i, (s, c) in enumerate(
            zip(orders.store.tolist(), orders.customer.tolist(), strict=True)
        )
    ]
    dirty_truth = []
    for k, (d, sec, s, position) in enumerate(bad_orders):
        when = datetime.combine(cal.start + timedelta(days=d), datetime.min.time()).replace(
            tzinfo=TZ
        ) + timedelta(seconds=sec)
        code = order_codes[orders.n + k]
        order_rows.append((code, stores.codes[s], None, when.isoformat(), position))
    order_rows.sort(key=lambda r: r[4])
    order_row_no = {}
    for row_no, r in enumerate(order_rows, start=1):
        order_row_no[r[0]] = row_no
    for k in range(len(bad_orders)):
        code = order_codes[orders.n + k]
        dirty_truth.append(
            {
                "file": "orders.csv",
                "row_no": order_row_no[code],
                "kind": "date_out_of_range",
                "order_code": code,
            }
        )
    counts["orders.csv"] = _write(
        out / "orders.csv",
        ("order_code", "store_code", "customer_code", "ordered_at"),
        (r[:4] for r in order_rows),
    )

    # order_lines.csv: grouped by order; broken lines sit inside their order.
    promo_codes = [p.code for p in promos]
    line_rows = [
        (o, ln, 0, products.skus[p], q, c, pr)
        for o, ln, p, q, c, pr in zip(
            lines.order.tolist(),
            lines.line_no.tolist(),
            lines.product.tolist(),
            lines.quantity.tolist(),
            lines.price_cents.tolist(),
            lines.promo.tolist(),
            strict=True,
        )
    ]
    for o, ln, sku, q, c, pr, kind, is_dup in extra_lines:
        line_rows.append(
            (o, ln, 1, sku, q, c, pr, kind) if is_dup else (o, ln, 0, sku, q, c, pr, kind)
        )
    line_rows.sort(key=lambda r: (r[0], r[1], r[2]))
    for row_no, r in enumerate(line_rows, start=1):
        if len(r) == 8:
            dirty_truth.append(
                {
                    "file": "order_lines.csv",
                    "row_no": row_no,
                    "kind": r[7],
                    "order_code": order_codes[r[0]],
                    "line_no": r[1],
                }
            )
    counts["order_lines.csv"] = _write(
        out / "order_lines.csv",
        ("order_code", "line_no", "sku", "quantity", "unit_price", "promo_code"),
        (
            (
                order_codes[r[0]],
                r[1],
                r[3],
                r[4],
                _money(r[5]),
                promo_codes[r[6]] if r[6] >= 0 else None,
            )
            for r in line_rows
        ),
    )
    counts["budgets.csv"] = _write(
        out / "budgets.csv",
        ("store_code", "month", "revenue_plan"),
        ((stores.codes[s], m.isoformat(), _money(v)) for s, m, v in budgets),
    )

    truth = _truth(
        config, cal, stores, products, promos, customers, orders, lines, margin_drop, fx, counts
    )
    truth["dirty_rows"] = sorted(dirty_truth, key=lambda r: (r["file"], r["row_no"]))
    with (out / "_truth.json").open("w", encoding="utf-8") as f:
        json.dump(truth, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    return counts


def _truth(
    config, cal, stores, products, promos, customers, orders, lines, margin_drop, fx, counts
):
    revenue = (lines.quantity * lines.price_cents).astype(float)
    by_product = np.sort(np.bincount(lines.product, weights=revenue, minlength=products.n))[::-1]
    top = max(1, round(products.n * 0.2))
    drop_cat, drop_from, drop_to = margin_drop
    return {
        "contract_version": "1.0",
        "config": json.loads(GeneratorConfig.model_dump_json(config)),
        "row_counts": counts,
        "row_no_convention": "1 = first data row after the header",
        "seasonality": {
            "monthly_factor": dict(zip(range(1, 13), MONTH_FACTOR, strict=True)),
            "category_monthly_factor": {c.code: list(c.season) for c in CATEGORIES},
            "store_weekday_factor": dict(
                zip(["mon", "tue", "wed", "thu", "fri", "sat"], STORE_WEEKDAY, strict=True)
            ),
            "online_weekday_factor": dict(
                zip(["mon", "tue", "wed", "thu", "fri", "sat", "sun"], ONLINE_WEEKDAY, strict=True)
            ),
            "online_evening_boost": {
                "days": ["sun", "mon"],
                "hours": "19-23",
                "factor": ONLINE_EVENING_BOOST,
            },
            "yearly_growth": YEARLY_GROWTH,
        },
        "calendar": {
            "public_holidays_stores_closed": {d.isoformat(): n for d, n in cal.holidays.items()},
            "trading_sundays": [d.isoformat() for d in cal.trading_sundays],
            "short_trading_days": [d.isoformat() for d in cal.short_days],
            "rule": "stores closed on public holidays and on Sundays except trading Sundays",
        },
        "black_friday": [
            {
                "black_friday": bf.isoformat(),
                "cyber_monday": (bf + timedelta(days=3)).isoformat(),
                "promo_code": f"BF-{bf.year}",
                "online_multiplier": BF_ONLINE,
                "store_multiplier": BF_STORE,
            }
            for bf in cal.black_fridays
        ],
        "weak_stores": [
            {
                "store_code": stores.codes[s],
                "traffic_multiplier": WEAK_FACTOR,
                "plan_multiplier": WEAK_PLAN_FACTOR,
                "expected_plan_realization": round(WEAK_FACTOR / WEAK_PLAN_FACTOR / PLAN_UPLIFT, 3),
            }
            for s in stores.weak
        ],
        "declining_stores": [
            {
                "store_code": stores.codes[s],
                "from_date": week.isoformat(),
                "drop_pct": round(1 - DECLINE_FACTOR, 2),
                "reason": "nowa konkurencja",
            }
            for s, week in stores.declining
        ],
        "margin_drop": {
            "category_code": CATEGORIES[drop_cat].code,
            "purchase_cost_increase_pct": MARGIN_DROP_PCT,
            "purchases_from": drop_from.isoformat(),
            "purchases_to": drop_to.isoformat(),
            "note": "order_lines.unit_cost_pln is a 90-day weighted average, so the margin drop "
            "in sales starts with the first purchases and fades ~90 days after purchases_to",
        },
        "churn": {
            "lifetime": "exponential",
            "mean_lifetime_days": LIFETIME_DAYS,
            "promo_cohort_rule": "registered on a day of a whole-assortment promotion "
            f"({', '.join(p.code for p in promos if p.whole_assortment)})",
            "promo_signup_boost": PROMO_SIGNUP_BOOST,
            "existing_customer_share": EXISTING_CUSTOMER_SHARE,
            "promo_cohort_customers": int(customers.promo_cohort.sum()),
            "store_identified_share": STORE_IDENTIFIED_SHARE,
            "first_order_on_registration_day": True,
        },
        "pareto": {
            "zipf_exponent": ZIPF_EXPONENT,
            "top_20pct_sku_revenue_share": round(
                float(by_product[:top].sum() / by_product.sum()), 4
            ),
        },
        "region": {
            "store_traffic": "proportional to size_m2 * purchasing_power_index",
            "online_customers_by": "population * purchasing_power_index",
        },
        "fx": {
            "eur_products": int(products.eur.sum()),
            "eur_product_share": round(float(products.eur.mean()), 4),
            "eur_price_list_rate": round(fx.mean_rate(config.purchases_start, config.end_date), 4),
            "note": "EUR unit costs are fixed at the average rate; their PLN cost follows NBP",
        },
        "promotions": {
            "volume_uplift": f"product weight x (1 + {PROMO_UPLIFT} x discount_pct)",
            "extra_quantity": f"Poisson({PROMO_EXTRA_QUANTITY} x discount_pct) units per line",
        },
    }
