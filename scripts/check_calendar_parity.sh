#!/usr/bin/env bash
# Compares the two independent Polish calendars:
#   * public.calendar in the database (supabase/migrations, used by dashboards and F7)
#   * datarift_pipeline.calendar_pl (used by the generator)
# Holidays, trading Sundays, Black Friday and Cyber Monday must match day for day,
# otherwise the generator plants store sales on days the DB considers closed.
# Needs a running local Supabase (supabase start / supabase db start) and uv.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
db_url=${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

years=$(psql "$db_url" -Atc "select min(extract(year from date))::int || ' ' || max(extract(year from date))::int from public.calendar")
read -r first last <<<"$years"

(cd "$root/pipeline" && uv run --quiet python - "$first" "$last") >"$tmp/py.txt" <<'PY'
import sys
from datarift_pipeline.calendar_pl import black_friday, cyber_monday, public_holidays, trading_sundays

first, last = int(sys.argv[1]), int(sys.argv[2])
rows = []
for y in range(first, last + 1):
    rows += [f"holiday {d}" for d in public_holidays(y)]
    rows += [f"trading_sunday {d}" for d in trading_sundays(y)]
    rows += [f"black_friday {black_friday(y)}", f"cyber_monday {cyber_monday(y)}"]
print("\n".join(sorted(rows)))
PY

psql "$db_url" -At >"$tmp/sql.txt" <<'SQL'
select line from (
  select 'holiday ' || date as line from public.calendar where is_holiday
  union all select 'trading_sunday ' || date from public.calendar where is_trading_sunday
  union all select 'black_friday ' || date from public.calendar where is_black_friday
  union all select 'cyber_monday ' || date from public.calendar where is_cyber_monday
) t order by line;
SQL

if diff -u --label python "$tmp/py.txt" --label database "$tmp/sql.txt"; then
  echo "Calendars match for $first-$last ($(wc -l <"$tmp/sql.txt" | tr -d ' ') special days)."
else
  echo "Calendar mismatch between pipeline/calendar_pl.py and the database calendar." >&2
  exit 1
fi
