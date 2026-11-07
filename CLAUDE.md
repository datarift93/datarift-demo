# CLAUDE.md

## Project

datarift-demo is a portfolio BI app for prospective data/analytics clients. It analyzes two years of sales for "Wisła", a fictional Polish retail chain (~25 stores across voivodeships + an online store), with data from a Python generator and real EUR/PLN rates from the NBP API.

Full requirements (Polish): [docs/requirements.md](docs/requirements.md). Read it before working on any feature.
Stage plan and progress: [docs/plan.md](docs/plan.md). Check it to see where the project is; tick items in the PR that completes them.

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
- **No secrets in code.** Use `.env` / `.env.local` only (gitignored, never committed); keep `.env.example` up to date. The Supabase secret key (`SUPABASE_SECRET_KEY`, formerly `service_role`) never reaches the browser.
- **Plan first**: before implementing, write a short plan and get it approved.
- **Small steps**: one focused change at a time, each with a test.
- **Branches + PRs**: never commit directly to `main`.

## Commands

Web app (run from the repo root):

```bash
pnpm install        # install dependencies
pnpm dev            # dev server on http://localhost:3000
pnpm lint           # ESLint
pnpm typecheck      # next typegen + tsc --noEmit
pnpm test           # Vitest unit tests (*.test.ts next to the code)
pnpm build          # production build
```

Before finishing a change, run `pnpm lint && pnpm typecheck && pnpm test`. CI runs the same checks plus `pnpm build` on every PR.

UI: shadcn/ui (Base UI primitives, `components/ui/`), Tailwind v4. Polish number/date formatting lives in `lib/format.ts`; always use it instead of ad-hoc `toLocaleString`. Next.js here is v16: check `node_modules/next/dist/docs/` before using an API (see `AGENTS.md`).

Database (local Supabase, needs Docker running):

```bash
supabase start                          # local stack; prints URLs and keys (copy to .env.local, see .env.example)
supabase db reset                       # re-apply all migrations + supabase/seed.sql
supabase migration new <name>           # new migration in supabase/migrations/
supabase test db                        # pgTAP tests in supabase/tests/database/
supabase stop
```

Every new table: `org_id` column, `enable row level security`, read policy with `private.is_org_member(org_id)`, write policies with `private.is_org_admin(org_id)`, and a pgTAP test (demo can read, cannot write, cannot see other orgs). `001_rls.test.sql` fails if any table in `public` has RLS off. Local demo login: `demo@datarift.local` (seed only).

Python pipeline (run from `pipeline/`, uses uv, Python 3.12):

```bash
uv sync                                         # install deps into pipeline/.venv
uv run datarift-pipeline config                 # validate and print config/generator.toml
uv run pytest                                   # tests in pipeline/tests/
uv run ruff check . && uv run ruff format --check .
```

Generator parameters live in `pipeline/config/generator.toml` and are validated by `GeneratorConfig` (pydantic). Generation must stay deterministic: same config + seed = same data.

## Environments

- **Production web**: https://datarift-demo.vercel.app (Vercel project `datarift-demo`; deploys from `main`).
- **Production DB**: Supabase project `omxybotjtzmyrankpfio` (eu-central-1), linked with `supabase link`.
  - Migrations: `supabase db push --remote --dry-run` first, then `supabase db push --remote`. `seed.sql` is local only; never push it.
  - Do **not** run `supabase config push`: `config.toml` holds local dev auth settings (no email confirmation, no MFA, localhost URLs). Change production auth settings in the dashboard.

## Agent hooks

`.claude/settings.json` runs two hooks for Claude Code sessions in this repo:
- after every Edit/Write, `.claude/hooks/lint-edited-file.sh` lints the changed file (ESLint for TS/JS, ruff for `pipeline/`); fix reported errors before moving on;
- before Bash, `.claude/hooks/guard-main.sh` blocks `git commit` on `main` and pushes to `main`, so the agent finds out before GitHub rejects it. On GitHub, `main` is protected: the Web, Database and Pipeline checks must pass, linear history, no force pushes.
