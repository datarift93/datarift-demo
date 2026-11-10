"use client";

import { DataTable, type Column } from "@/components/data/data-table";
import { DIMENSION_LABEL, SEGMENT_INFO, type ScoreBand, type SegmentRow } from "@/lib/customers";
import { formatInteger, formatPercent, formatPLN } from "@/lib/format";

const decimal = new Intl.NumberFormat("pl-PL", { maximumFractionDigits: 1, minimumFractionDigits: 1 });

/** Six tiles in rule order: customers lead, revenue and the description follow. */
export function SegmentTiles({ rows }: { rows: SegmentRow[] }) {
  return (
    <ul className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
      {rows.map((r) => (
        <li key={r.segment} className="flex flex-col gap-2 rounded-lg border p-4">
          <div className="flex items-baseline justify-between gap-2">
            <h3 className="font-medium">{r.segment}</h3>
            <span className="text-xs text-muted-foreground">{SEGMENT_INFO[r.segment].rule}</span>
          </div>
          <p className="flex flex-wrap items-baseline gap-x-2">
            <span className="text-2xl font-semibold tabular-nums">{formatInteger(r.customers)}</span>
            <span className="text-sm text-muted-foreground">
              klientów · {formatPercent(r.shareCustomers)} wszystkich
            </span>
          </p>
          {/* Share of customers vs share of revenue: one hue, two bars, labelled in text. */}
          <div className="flex flex-col gap-1 text-xs text-muted-foreground" aria-hidden>
            <ShareBar ratio={r.shareCustomers} label="klienci" />
            <ShareBar ratio={r.shareRevenue} label="przychód" />
          </div>
          <p className="text-sm">
            <span className="font-medium tabular-nums">{formatPLN(r.revenue, { whole: true })}</span>{" "}
            <span className="text-muted-foreground">
              przychodu w 12 mies. ({formatPercent(r.shareRevenue)})
            </span>
          </p>
          <p className="text-sm text-muted-foreground">{SEGMENT_INFO[r.segment].description}</p>
        </li>
      ))}
    </ul>
  );
}

function ShareBar({ ratio, label }: { ratio: number; label: string }) {
  return (
    <div className="grid grid-cols-[4.5rem_1fr] items-center gap-2">
      <span>{label}</span>
      <span className="h-1.5 rounded-full bg-[var(--viz-grid)]">
        <span
          className="block h-full rounded-full bg-[var(--viz-series-1)]"
          style={{ width: `${Math.min(ratio, 1) * 100}%` }}
        />
      </span>
    </div>
  );
}

const ORDER = Object.keys(SEGMENT_INFO);

const columns: Column<SegmentRow>[] = [
  {
    key: "segment",
    header: "Segment",
    sortable: true,
    sortValue: (r) => ORDER.indexOf(r.segment),
    cell: (r) => <span className="font-medium">{r.segment}</span>,
  },
  { key: "customers", header: "Klienci", align: "right", sortable: true, cell: (r) => formatInteger(r.customers) },
  {
    key: "shareCustomers",
    header: "% klientów",
    align: "right",
    sortable: true,
    cell: (r) => formatPercent(r.shareCustomers),
  },
  {
    key: "revenue",
    header: "Przychód 12 mies.",
    align: "right",
    sortable: true,
    cell: (r) => formatPLN(r.revenue),
  },
  {
    key: "shareRevenue",
    header: "% przychodu",
    align: "right",
    sortable: true,
    cell: (r) => formatPercent(r.shareRevenue),
  },
  {
    key: "avgRecencyDays",
    header: "Śr. dni od zakupu",
    align: "right",
    sortable: true,
    cell: (r) => (r.avgRecencyDays === null ? "–" : formatInteger(r.avgRecencyDays)),
  },
  {
    key: "avgFrequency",
    header: "Śr. zamówień 12 mies.",
    align: "right",
    sortable: true,
    cell: (r) => (r.avgFrequency === null ? "–" : decimal.format(r.avgFrequency)),
  },
];

export function SegmentTable({ rows }: { rows: SegmentRow[] }) {
  return (
    <DataTable
      columns={columns}
      rows={rows}
      rowKey={(r) => r.segment}
      initialSort={{ key: "segment", dir: "asc" }}
      caption="Segmenty RFM: liczba klientów, przychód i udziały"
    />
  );
}

function bandValue(b: ScoreBand, v: number): string {
  return b.dimension === "M" ? formatPLN(v, { whole: true }) : formatInteger(v);
}

/** What each score 1-5 means for the current filters (value range and customers per band). */
export function ScoreBands({ bands }: { bands: ScoreBand[] }) {
  const dims = (["R", "F", "M"] as const).map((d) => ({ d, rows: bands.filter((b) => b.dimension === d) }));
  return (
    <div className="grid gap-3 lg:grid-cols-3">
      {dims.map(({ d, rows }) => (
        <div key={d} className="overflow-x-auto rounded-lg border">
          <table className="w-full text-left text-sm">
            <caption className="px-3 pt-2 text-left font-medium">{DIMENSION_LABEL[d]}</caption>
            <thead>
              <tr className="border-b text-muted-foreground">
                <th className="px-3 py-1.5 font-medium">Ocena</th>
                <th className="px-3 py-1.5 text-right font-medium">Zakres</th>
                <th className="px-3 py-1.5 text-right font-medium">Klienci</th>
              </tr>
            </thead>
            <tbody>
              {[...rows].reverse().map((b) => (
                <tr key={b.score} className="border-b last:border-0">
                  <td className="px-3 py-1.5 tabular-nums">{b.score}</td>
                  <td className="px-3 py-1.5 text-right tabular-nums whitespace-nowrap">
                    {b.min === b.max ? bandValue(b, b.min) : `${bandValue(b, b.min)} – ${bandValue(b, b.max)}`}
                  </td>
                  <td className="px-3 py-1.5 text-right tabular-nums">{formatInteger(b.customers)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ))}
    </div>
  );
}
