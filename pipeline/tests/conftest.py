import csv
import json
from dataclasses import dataclass
from pathlib import Path

import pytest

from datarift_pipeline.config import load_config
from datarift_pipeline.generator import generate
from datarift_pipeline.nbp import read_rates

PIPELINE_DIR = Path(__file__).resolve().parents[1]
CONFIG_PATH = PIPELINE_DIR / "config" / "generator.toml"
RATES_PATH = PIPELINE_DIR / "data" / "fx_eur_pln.csv"


@dataclass
class Dataset:
    path: Path
    truth: dict
    header: dict[str, list[str]]
    rows: dict[str, list[dict[str, str]]]

    def clean(self, name: str) -> list[dict[str, str]]:
        """Rows of a file without the deliberately broken ones listed in _truth.json."""
        bad = {r["row_no"] for r in self.truth["dirty_rows"] if r["file"] == name}
        return [r for i, r in enumerate(self.rows[name], start=1) if i not in bad]


def load_dataset(path: Path) -> Dataset:
    header, rows = {}, {}
    for f in sorted(path.glob("*.csv")):
        with f.open(encoding="utf-8", newline="") as fh:
            reader = csv.DictReader(fh)
            rows[f.name] = list(reader)
            header[f.name] = list(reader.fieldnames or [])
    truth = json.loads((path / "_truth.json").read_text(encoding="utf-8"))
    return Dataset(path, truth, header, rows)


@pytest.fixture(scope="session")
def default_dataset(tmp_path_factory) -> Dataset:
    """The full dataset at the committed default config (~2 s to generate)."""
    out = tmp_path_factory.mktemp("default")
    generate(load_config(CONFIG_PATH), read_rates(RATES_PATH), out)
    return load_dataset(out)
