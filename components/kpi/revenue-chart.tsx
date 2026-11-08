"use client";

import { Bar, BarChart, CartesianGrid, Cell, Tooltip, XAxis, YAxis, type TooltipContentProps } from "recharts";

import { ChartContainer, type ChartConfig } from "@/components/ui/chart";
import type { SeriesPoint } from "@/lib/data/kpi";
import { formatInteger, formatPLN, formatPLNCompact } from "@/lib/format";
import { bucketCoverage, bucketLabel, bucketTick, GRAIN_LABEL, type Grain } from "@/lib/kpi";

const config = {
  revenue: { label: "Przychód", color: "var(--viz-series-1)" },
} satisfies ChartConfig;

type Point = SeriesPoint & { label: string; days: number; full: number };

/** Value leads, label follows; text in ink colors, the series color only as a short key. */
function BucketTooltip({ active, payload }: TooltipContentProps<number, string>) {
  const p = active ? (payload?.[0]?.payload as Point | undefined) : undefined;
  if (!p) return null;
  return (
    <div className="rounded-md border bg-background px-3 py-2 text-xs shadow-md">
      <p className="mb-1 text-muted-foreground">{p.label}</p>
      <p className="flex items-center gap-2">
        <span className="h-0.5 w-3 rounded-full bg-[var(--viz-series-1)]" aria-hidden />
        <span className="font-semibold tabular-nums">{formatPLN(p.revenue)}</span>
        <span className="text-muted-foreground">przychód</span>
      </p>
      <p className="mt-0.5 pl-5 text-muted-foreground tabular-nums">
        {formatInteger(p.orders)} zamówień · marża {formatPLN(p.margin)}
      </p>
      {p.days < p.full && (
        <p className="mt-1 pl-5 text-muted-foreground">
          Niepełny okres: {p.days} z {p.full} dni
        </p>
      )}
    </div>
  );
}

export function RevenueChart({ series, grain, to }: { series: SeriesPoint[]; grain: Grain; to: string }) {
  const data: Point[] = series.map((p) => ({
    ...p,
    label: bucketLabel(p.bucket, grain),
    ...bucketCoverage(p.bucket, grain, to),
  }));
  const hasPartial = data.some((p) => p.days < p.full);

  return (
    <figure className="flex flex-col gap-3">
      <figcaption className="flex flex-wrap items-baseline justify-between gap-2">
        <span className="font-medium">Przychód w czasie</span>
        <span className="text-sm text-muted-foreground">{GRAIN_LABEL[grain]}</span>
      </figcaption>

      <ChartContainer config={config} className="aspect-auto h-64 w-full sm:h-72">
        <BarChart data={data} margin={{ top: 8, right: 4, left: 4, bottom: 0 }} barCategoryGap={2}>
          <CartesianGrid vertical={false} stroke="var(--viz-grid)" />
          <XAxis
            dataKey="bucket"
            tickLine={false}
            axisLine={{ stroke: "var(--viz-grid)" }}
            tick={{ fill: "var(--viz-axis)", fontSize: 12 }}
            tickFormatter={(b: string) => bucketTick(b, grain)}
            minTickGap={24}
          />
          <YAxis
            width={84}
            tickLine={false}
            axisLine={false}
            tick={{ fill: "var(--viz-axis)", fontSize: 12 }}
            tickFormatter={(v: number) => formatPLNCompact(v)}
          />
          <Tooltip
            cursor={{ fill: "var(--viz-grid)", opacity: 0.5 }}
            content={(props) => <BucketTooltip {...(props as TooltipContentProps<number, string>)} />}
          />
          <Bar dataKey="revenue" fill="var(--color-revenue)" radius={[4, 4, 0, 0]} maxBarSize={24}>
            {/* Partial first/last buckets are lighter, so they don't read as a drop in sales. */}
            {data.map((p) => (
              <Cell key={p.bucket} fillOpacity={p.days < p.full ? 0.4 : 1} />
            ))}
          </Bar>
        </BarChart>
      </ChartContainer>

      {hasPartial && (
        <p className="text-xs text-muted-foreground">
          Jaśniejsze słupki to niepełne okresy na początku lub końcu zakresu (najedź, aby zobaczyć liczbę dni).
        </p>
      )}

      {/* The same numbers as a table: reachable without hover, by keyboard and screen readers. */}
      <details className="text-sm">
        <summary className="cursor-pointer text-muted-foreground hover:text-foreground">
          Pokaż dane w tabeli
        </summary>
        <div className="mt-2 max-h-72 overflow-auto rounded-lg border">
          <table className="w-full text-left">
            <caption className="sr-only">Przychód w czasie ({GRAIN_LABEL[grain]})</caption>
            <thead className="sticky top-0 bg-background">
              <tr className="border-b">
                <th className="px-3 py-2 font-medium">Okres</th>
                <th className="px-3 py-2 text-right font-medium">Przychód</th>
                <th className="px-3 py-2 text-right font-medium">Marża</th>
                <th className="px-3 py-2 text-right font-medium">Zamówienia</th>
              </tr>
            </thead>
            <tbody>
              {data.map((p) => (
                <tr key={p.bucket} className="border-b last:border-0">
                  <td className="px-3 py-1.5">
                    {p.label}
                    {p.days < p.full && <span className="text-muted-foreground"> ({p.days} z {p.full} dni)</span>}
                  </td>
                  <td className="px-3 py-1.5 text-right tabular-nums">{formatPLN(p.revenue)}</td>
                  <td className="px-3 py-1.5 text-right tabular-nums">{formatPLN(p.margin)}</td>
                  <td className="px-3 py-1.5 text-right tabular-nums">{formatInteger(p.orders)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </details>
    </figure>
  );
}
