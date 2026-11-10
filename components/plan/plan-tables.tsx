"use client";

import { DataTable, type Column } from "@/components/data/data-table";
import { formatInteger, formatPLN } from "@/lib/format";
import type { PlanFigures, RegionSummary, StoreSummary } from "@/lib/plan";

import { Realization } from "./plan-status";

const signed = (v: number) => (v > 0 ? `+${formatPLN(v, { whole: true })}` : formatPLN(v, { whole: true }));

function figureColumns<Row extends PlanFigures>(): Column<Row>[] {
  return [
    { key: "plan", header: "Plan", sortable: true, align: "right", cell: (r) => formatPLN(r.plan, { whole: true }) },
    {
      key: "actual",
      header: "Wykonanie",
      sortable: true,
      align: "right",
      cell: (r) => formatPLN(r.actual, { whole: true }),
    },
    {
      key: "realization",
      header: "Realizacja",
      sortable: true,
      align: "right",
      cell: (r) => <Realization value={r.realization} />,
    },
    { key: "deviation", header: "Odchylenie", sortable: true, align: "right", cell: (r) => signed(r.deviation) },
  ];
}

const regionColumns: Column<RegionSummary>[] = [
  { key: "regionName", header: "Województwo", sortable: true, className: "font-medium" },
  { key: "stores", header: "Sklepy", sortable: true, align: "right", cell: (r) => formatInteger(r.stores) },
  ...figureColumns<RegionSummary>(),
];

const storeColumns: Column<StoreSummary>[] = [
  {
    key: "storeName",
    header: "Sklep",
    sortable: true,
    sortValue: (r) => r.storeCode,
    cell: (r) => (
      <span className="flex flex-col">
        <span className="font-medium">{r.storeName}</span>
        <span className="text-xs text-muted-foreground">{r.storeCode}</span>
      </span>
    ),
  },
  {
    key: "regionName",
    header: "Województwo",
    sortable: true,
    cell: (r) => (r.regionCode === null ? <span className="text-muted-foreground">– (online)</span> : r.regionName),
  },
  ...figureColumns<StoreSummary>(),
];

export function RegionTable({ regions }: { regions: RegionSummary[] }) {
  return (
    <DataTable
      columns={regionColumns}
      rows={regions}
      rowKey={(r) => r.key}
      initialSort={{ key: "realization", dir: "asc" }}
      caption="Realizacja planu według województw"
    />
  );
}

export function StoreTable({ stores }: { stores: StoreSummary[] }) {
  return (
    <DataTable
      columns={storeColumns}
      rows={stores}
      rowKey={(r) => r.storeCode}
      initialSort={{ key: "realization", dir: "asc" }}
      caption="Realizacja planu według sklepów"
    />
  );
}
