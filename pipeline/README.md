# datarift-pipeline

Python data generator and import pipeline for datarift-demo: generator → staging → validation → model → import log, plus EUR/PLN rates from the NBP API.

```bash
uv sync
uv run datarift-pipeline config   # validate and print config/generator.toml
uv run pytest
uv run ruff check . && uv run ruff format --check .
```
