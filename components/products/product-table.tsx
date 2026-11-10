"use client";

import { DataTable, type Column } from "@/components/data/data-table";
import { formatInteger, formatPercent, formatPLN } from "@/lib/format";
import type { ProductRow } from "@/lib/products";

const columns: Column<ProductRow>[] = [
  { key: "rank", header: "#", sortable: true, align: "right", cell: (r) => r.rank },
  {
    key: "name",
    header: "Produkt",
    sortable: true,
    className: "min-w-48",
    cell: (r) => (
      <div className="flex flex-col">
        <span>{r.name}</span>
        <span className="text-xs text-muted-foreground">{r.sku}</span>
      </div>
    ),
  },
  { key: "categoryName", header: "Kategoria", sortable: true },
  {
    key: "abcClass",
    header: "Klasa",
    sortable: true,
    sortValue: (r) => r.rank, // A before B before C, in ranking order
    cell: (r) => (
      <span className="inline-flex size-6 items-center justify-center rounded-md border text-xs font-semibold">
        {r.abcClass}
      </span>
    ),
  },
  {
    key: "currency",
    header: "Zakup",
    sortable: true,
    cell: (r) =>
      r.currency === "EUR" ? (
        <span title="Koszt zakupu w EUR, przeliczony po kursie NBP z dnia zakupu">EUR · import</span>
      ) : (
        <span className="text-muted-foreground">PLN</span>
      ),
  },
  { key: "revenue", header: "Przychód", sortable: true, align: "right", cell: (r) => formatPLN(r.revenue) },
  { key: "margin", header: "Marża", sortable: true, align: "right", cell: (r) => formatPLN(r.margin) },
  {
    key: "marginPct",
    header: "Marża %",
    sortable: true,
    align: "right",
    cell: (r) => (r.marginPct === null ? "–" : formatPercent(r.marginPct)),
  },
  { key: "units", header: "Sztuki", sortable: true, align: "right", cell: (r) => formatInteger(r.units) },
  { key: "orders", header: "Zamówienia", sortable: true, align: "right", cell: (r) => formatInteger(r.orders) },
];

export function ProductTable({ rows }: { rows: ProductRow[] }) {
  return (
    <DataTable
      columns={columns}
      rows={rows}
      rowKey={(r) => r.sku}
      initialSort={{ key: "revenue", dir: "desc" }}
      caption="Ranking produktów"
      empty="Brak sprzedaży produktów dla wybranych filtrów."
    />
  );
}
