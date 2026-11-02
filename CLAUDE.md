# CLAUDE.md

## Project

datarift-demo is a portfolio BI app for prospective data/analytics clients. It analyzes two years of sales for "Wisła", a fictional Polish retail chain (~25 stores across voivodeships + an online store), with data from a Python generator and real EUR/PLN rates from the NBP API.

Full requirements (Polish): [docs/requirements.md](docs/requirements.md). Read it before working on any feature.

## Stack

- **Next.js** (App Router, TypeScript `strict`), **pnpm**
- **Supabase**: Postgres, Auth, RLS
- **Vercel**: hosting
- **Python**: data generator and import pipeline
- **GitHub Actions**: CI

## Structure

```
/                 Next.js app (app/, components/, lib/, package.json)
supabase/         Supabase config, migrations/, seed, RLS tests
pipeline/         Python: data generator, NBP rates fetch, staging -> validation -> model -> import log
docs/             Requirements and project docs
.github/workflows CI
```

## Rules

- **Language**: code, identifiers, comments, commits and DB names in English. **All UI text in Polish** (amounts in zł, Polish number/date formats).
- **Schema changes only through Supabase migrations** (`supabase/migrations/`). Never edit the schema by hand in the dashboard.
- **RLS enabled on every table**, with policies scoped by `org_id`. The `demo` role is read-only, enforced in the database and not only in the UI.
- **Aggregations in the database** (views / materialized views), not in the client.
- **No secrets in code.** Use `.env` / `.env.local` only (gitignored, never committed); keep `.env.example` up to date. The `service_role` key never reaches the browser.
- **Plan first**: before implementing, write a short plan and get it approved.
- **Small steps**: one focused change at a time, each with a test.
- **Branches + PRs**: never commit directly to `main`.

## Commands

> TODO: fill in during Stage 1 (Etap 1).

```bash
# TODO: install       (pnpm install)
# TODO: dev server    (pnpm dev)
# TODO: lint / typecheck / test
# TODO: Supabase local + migrations
# TODO: Python pipeline: generate data, fetch NBP rates, run import
```
