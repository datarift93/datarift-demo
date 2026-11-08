"use client";


import { DataTable, type Column } from "@/components/data/data-table";
import { FilterLink } from "@/components/shell/filter-link";
import { Badge } from "@/components/ui/badge";
import type { ImportErrorRow, ImportRun, ImportStatus } from "@/lib/data/imports";
import { formatDate, formatDateTime, formatDuration, formatInteger } from "@/lib/format";

const STATUS: Record<ImportStatus, { label: string; variant: "default" | "secondary" | "destructive" | "outline" }> = {
  success: { label: "Sukces", variant: "default" },
  partial: { label: "Częściowy", variant: "secondary" },
  failed: { label: "Błąd", variant: "destructive" },
  running: { label: "W toku", variant: "outline" },
};

export function StatusBadge({ status }: { status: ImportStatus }) {
  const s = STATUS[status];
  return <Badge variant={s.variant}>{s.label}</Badge>;
}

const count = (n: number | null) => (n === null ? "–" : formatInteger(n));

const runColumns: Column<ImportRun>[] = [
  {
    key: "startedAt",
    header: "Data",
    sortable: true,
    cell: (r) => (
      <FilterLink href={`/importy/${r.id}`} className="font-medium underline-offset-4 hover:underline">
        {formatDateTime(r.startedAt)}
      </FilterLink>
    ),
  },
  {
    key: "status",
    header: "Status",
    sortable: true,
    sortValue: (r) => STATUS[r.status].label,
    cell: (r) => <StatusBadge status={r.status} />,
  },
  {
    key: "period",
    header: "Okres danych",
    cell: (r) => `${formatDate(r.periodStart)} – ${formatDate(r.periodEnd)}`,
  },
  {
    key: "seconds",
    header: "Czas trwania",
    sortable: true,
    align: "right",
    cell: (r) => (r.seconds === null ? "–" : formatDuration(r.seconds)),
  },
  { key: "rowsRead", header: "Wczytane", sortable: true, align: "right", cell: (r) => count(r.rowsRead) },
  { key: "rowsValid", header: "Poprawne", sortable: true, align: "right", cell: (r) => count(r.rowsValid) },
  { key: "rowsRejected", header: "Odrzucone", sortable: true, align: "right", cell: (r) => count(r.rowsRejected) },
];

export function ImportRunsTable({ runs }: { runs: ImportRun[] }) {
  return (
    <DataTable
      caption="Historia importów"
      columns={runColumns}
      rows={runs}
      rowKey={(r) => r.id}
      initialSort={{ key: "startedAt", dir: "desc" }}
      empty="Nie było jeszcze żadnego importu."
    />
  );
}

const errorColumns: Column<ImportErrorRow>[] = [
  { key: "file", header: "Plik", sortable: true, className: "font-mono text-xs" },
  { key: "rowNo", header: "Wiersz", sortable: true, align: "right", cell: (e) => formatInteger(e.rowNo) },
  { key: "field", header: "Pole", sortable: true, className: "font-mono text-xs" },
  { key: "message", header: "Opis błędu", sortable: true, className: "min-w-72 whitespace-normal" },
];

export function ImportErrorsTable({ errors }: { errors: ImportErrorRow[] }) {
  return (
    <DataTable
      caption="Błędy walidacji"
      columns={errorColumns}
      rows={errors}
      rowKey={(e) => e.id}
      empty="Ten import nie odrzucił żadnego wiersza."
    />
  );
}
