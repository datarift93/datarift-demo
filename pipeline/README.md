# datarift-pipeline

Python data generator and import pipeline for datarift-demo: generator → staging → validation → model → import log, plus EUR/PLN rates from the NBP API.

```bash
uv sync
uv run datarift-pipeline config        # validate and print config/generator.toml
uv run datarift-pipeline fetch-rates   # refresh data/fx_eur_pln.csv from the NBP API (committed)
uv run datarift-pipeline generate      # write out/*.csv + out/_truth.json (~2 s)
uv run pytest
uv run ruff check . && uv run ruff format --check .
```

## Generated data

`generate` reads `config/generator.toml` and the committed NBP rates (`data/fx_eur_pln.csv`), never
the API, so the same seed gives byte-identical files. The files follow `docs/data-model.md`;
`out/_truth.json` lists the planted signals (weak and declining stores, margin drop, Black Friday,
churn cohorts...) and every deliberately broken row (`row_no` 1 = first data row after the header). All money amounts are net (excluding VAT).

Modules: `calendar_pl.py` (holidays, trading Sundays, Black Friday), `reference.py` (voivodeships
with TERYT codes, cities, categories, product names), `generator.py` (the generator), `nbp.py`
(rates fetch and the "rate on the date or the last business day before it" lookup).
