import "server-only";

import { getCurrentUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export type ImportStatus = "running" | "success" | "partial" | "failed";

export type ImportRun = {
  id: number;
  status: ImportStatus;
  source: string;
  periodStart: string;
  periodEnd: string;
  startedAt: string;
  seconds: number | null;
  rowsRead: number | null;
  rowsValid: number | null;
  rowsRejected: number | null;
  errorMessage: string | null;
};

export type ImportErrorRow = {
  id: number;
  file: string;
  rowNo: number;
  field: string;
  message: string;
};

type RunRow = {
  id: number;
  status: ImportStatus;
  source: string;
  period_start: string;
  period_end: string;
  started_at: string;
  finished_at: string | null;
  rows_read: number | null;
  rows_valid: number | null;
  rows_rejected: number | null;
  error_message: string | null;
};

const RUN_COLUMNS =
  "id, status, source, period_start, period_end, started_at, finished_at, rows_read, rows_valid, rows_rejected, error_message";

function toRun(r: RunRow): ImportRun {
  return {
    id: r.id,
    status: r.status,
    source: r.source,
    periodStart: r.period_start,
    periodEnd: r.period_end,
    startedAt: r.started_at,
    seconds: r.finished_at ? (Date.parse(r.finished_at) - Date.parse(r.started_at)) / 1000 : null,
    rowsRead: r.rows_read,
    rowsValid: r.rows_valid,
    rowsRejected: r.rows_rejected,
    errorMessage: r.error_message,
  };
}

/** Import history of the user's org (RLS), newest first. */
export async function listImportRuns(): Promise<ImportRun[]> {
  const [supabase, user] = await Promise.all([createClient(), getCurrentUser()]);
  const { data, error } = await supabase
    .from("import_runs")
    .select(RUN_COLUMNS)
    .eq("org_id", user.orgId)
    .order("started_at", { ascending: false })
    .limit(200);
  if (error) throw new Error(`Nie udało się wczytać historii importów: ${error.message}`);
  return (data as RunRow[]).map(toRun);
}

// The Data API returns at most 1000 rows per request (Supabase `max_rows`) and silently
// truncates the rest, so errors are fetched in pages. MAX_ERRORS bounds the page weight;
// `total` is always the exact count, so the UI can say when the list is cut.
const PAGE_SIZE = 1000;
export const MAX_ERRORS = 10_000;

export type ImportRunDetails = { run: ImportRun; errors: ImportErrorRow[]; totalErrors: number };

/** One run with its validation errors, or null when it does not exist (or is another org's). */
export async function getImportRun(id: number): Promise<ImportRunDetails | null> {
  const [supabase, user] = await Promise.all([createClient(), getCurrentUser()]);
  const [run, count] = await Promise.all([
    supabase.from("import_runs").select(RUN_COLUMNS).eq("id", id).eq("org_id", user.orgId).maybeSingle(),
    supabase.from("import_errors").select("id", { count: "exact", head: true }).eq("import_run_id", id),
  ]);
  if (run.error) throw new Error(`Nie udało się wczytać importu: ${run.error.message}`);
  if (count.error) throw new Error(`Nie udało się policzyć błędów importu: ${count.error.message}`);
  if (!run.data) return null;

  const total = count.count ?? 0;
  const pages = Math.ceil(Math.min(total, MAX_ERRORS) / PAGE_SIZE);
  const results = await Promise.all(
    Array.from({ length: pages }, (_, i) =>
      supabase
        .from("import_errors")
        .select("id, file, row_no, field, message")
        .eq("import_run_id", id)
        .order("id") // stable order across pages
        .range(i * PAGE_SIZE, Math.min((i + 1) * PAGE_SIZE, MAX_ERRORS) - 1),
    ),
  );
  const errors: ImportErrorRow[] = [];
  for (const r of results) {
    if (r.error) throw new Error(`Nie udało się wczytać błędów importu: ${r.error.message}`);
    for (const e of r.data ?? []) {
      errors.push({ id: e.id, file: e.file, rowNo: e.row_no, field: e.field, message: e.message });
    }
  }
  errors.sort((a, b) => a.file.localeCompare(b.file) || a.rowNo - b.rowNo || a.id - b.id);
  return { run: toRun(run.data as RunRow), errors, totalErrors: total };
}
