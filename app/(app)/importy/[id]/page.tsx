import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { Suspense } from "react";

import { PageHeader, TableSkeleton } from "@/components/data/states";
import { FilterLink } from "@/components/shell/filter-link";
import { getImportRun } from "@/lib/data/imports";
import { formatDate, formatDateTime, formatDuration, formatInteger } from "@/lib/format";

import { ImportErrorsTable, StatusBadge } from "../import-tables";

export const metadata: Metadata = { title: "Szczegóły importu | Wisła · demo BI" };

function Stat({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="rounded-lg border p-3">
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="mt-1 font-medium tabular-nums">{value}</dd>
    </div>
  );
}

async function RunDetails({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const runId = Number(id);
  if (!Number.isSafeInteger(runId) || runId <= 0) notFound();
  const result = await getImportRun(runId);
  if (!result) notFound();
  const { run, errors, totalErrors } = result;

  return (
    <>
      <PageHeader title={`Import z ${formatDateTime(run.startedAt)}`} description={run.source} />
      <dl className="mb-6 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
        <Stat label="Status" value={<StatusBadge status={run.status} />} />
        <Stat label="Okres danych" value={`${formatDate(run.periodStart)} – ${formatDate(run.periodEnd)}`} />
        <Stat label="Czas trwania" value={run.seconds === null ? "–" : formatDuration(run.seconds)} />
        <Stat label="Wczytane" value={run.rowsRead === null ? "–" : formatInteger(run.rowsRead)} />
        <Stat label="Poprawne" value={run.rowsValid === null ? "–" : formatInteger(run.rowsValid)} />
        <Stat label="Odrzucone" value={run.rowsRejected === null ? "–" : formatInteger(run.rowsRejected)} />
      </dl>
      {run.errorMessage && (
        <p role="alert" className="mb-6 rounded-lg border border-destructive/40 p-3 text-sm">
          Import przerwany: {run.errorMessage}
        </p>
      )}
      <h2 className="mb-3 font-medium">Błędy walidacji ({formatInteger(totalErrors)})</h2>
      {errors.length < totalErrors && (
        <p className="mb-3 text-sm text-muted-foreground">
          Pokazano pierwsze {formatInteger(errors.length)} z {formatInteger(totalErrors)} błędów.
        </p>
      )}
      <ImportErrorsTable errors={errors} />
    </>
  );
}

export default function ImportRunPage({ params }: PageProps<"/importy/[id]">) {
  return (
    <>
      <FilterLink href="/importy" className="mb-4 inline-block text-sm text-muted-foreground hover:underline">
        ← Wszystkie importy
      </FilterLink>
      <Suspense fallback={<TableSkeleton />}>
        <RunDetails params={params} />
      </Suspense>
    </>
  );
}
