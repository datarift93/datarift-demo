"""Generator configuration: loaded from TOML and validated before any data is generated."""

import tomllib
from datetime import date
from pathlib import Path
from typing import Self

from pydantic import BaseModel, ConfigDict, Field, model_validator

DEFAULT_CONFIG_PATH = Path(__file__).resolve().parents[2] / "config" / "generator.toml"


class GeneratorConfig(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    seed: int = Field(ge=0)
    start_date: date
    end_date: date
    store_count: int = Field(ge=1, le=100)
    online_store: bool = True
    customer_count: int = Field(ge=1)
    scale: float = Field(gt=0, le=10)

    @model_validator(mode="after")
    def check_date_range(self) -> Self:
        if self.end_date <= self.start_date:
            raise ValueError("end_date must be after start_date")
        # Year-over-year comparisons (anomalies, cohorts) need at least one full year.
        if (self.end_date - self.start_date).days < 365:
            raise ValueError("date range must cover at least one full year")
        return self

    @property
    def days(self) -> int:
        return (self.end_date - self.start_date).days + 1


def load_config(path: Path = DEFAULT_CONFIG_PATH) -> GeneratorConfig:
    with path.open("rb") as f:
        return GeneratorConfig.model_validate(tomllib.load(f))
