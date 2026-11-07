"""Generator configuration: loaded from TOML and validated before any data is generated."""

import os
import tomllib
from datetime import date, timedelta
from pathlib import Path
from typing import Self

from pydantic import BaseModel, ConfigDict, Field, model_validator

# Relative to the working directory (commands run from pipeline/), so it works the same
# for editable installs, wheels and containers. Override with DATARIFT_CONFIG or --path.
CONFIG_ENV_VAR = "DATARIFT_CONFIG"
DEFAULT_CONFIG_PATH = Path("config/generator.toml")

# Upper bounds keep the generated data within the Supabase free tier (~500 MB,
# roughly 300-600k order lines at scale 1.0).
MAX_CUSTOMERS = 200_000
MAX_SCALE = 3.0
MAX_PRODUCTS = 2000


class GeneratorConfig(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    seed: int = Field(ge=0)
    start_date: date
    end_date: date
    store_count: int = Field(ge=1, le=100)
    online_store: bool = True
    customer_count: int = Field(ge=1, le=MAX_CUSTOMERS)
    scale: float = Field(gt=0, le=MAX_SCALE)
    product_count: int = Field(default=400, ge=50, le=MAX_PRODUCTS)
    # Share of deliberately broken rows (orders + order lines) for the import error list (F4).
    dirty_row_rate: float = Field(default=0.002, ge=0, le=0.05)
    # Planted store signals: permanently weak stores and stores with a sudden drop.
    weak_store_count: int = Field(default=3, ge=0)
    declining_store_count: int = Field(default=2, ge=0)
    # Purchases (and NBP rates) start this many days before start_date, so every sale has
    # purchase costs from the 90 days before it.
    purchase_lookback_days: int = Field(default=120, ge=90, le=365)

    @model_validator(mode="after")
    def check_date_range(self) -> Self:
        if self.end_date <= self.start_date:
            raise ValueError("end_date must be after start_date")
        # Year-over-year comparisons (anomalies, cohorts) need at least one full year.
        if self.days < 365:
            raise ValueError("date range must cover at least one full year")
        if self.weak_store_count + self.declining_store_count > self.store_count:
            raise ValueError("weak_store_count + declining_store_count exceeds store_count")
        return self

    @property
    def days(self) -> int:
        """Number of days in the range, both ends included."""
        return (self.end_date - self.start_date).days + 1

    @property
    def purchases_start(self) -> date:
        """First day with purchases (and the first NBP rate needed)."""
        return self.start_date - timedelta(days=self.purchase_lookback_days)


def default_config_path() -> Path:
    return Path(os.environ.get(CONFIG_ENV_VAR, DEFAULT_CONFIG_PATH))


def load_config(path: Path | None = None) -> GeneratorConfig:
    with (path or default_config_path()).open("rb") as f:
        return GeneratorConfig.model_validate(tomllib.load(f))
