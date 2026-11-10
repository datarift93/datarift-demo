"use client";

import {
  CartesianGrid,
  Line,
  LineChart,
  ReferenceLine,
  Tooltip,
  XAxis,
  YAxis,
  type TooltipContentProps,
} from "recharts";

import { ChartContainer, type ChartConfig } from "@/components/ui/chart";
import { formatPercent } from "@/lib/format";
import {
  ABC_THRESHOLDS,
  classBoundaries,
  paretoPoints,
  topShare,
  type ParetoPoint,
  type ProductRow,
} from "@/lib/products";

const config = {
  y: { label: "Skumulowany udział w przychodzie", color: "var(--viz-series-1)" },
} satisfies ChartConfig;

const TICKS = [0, 0.2, 0.4, 0.6, 0.8, 1];
const pct0 = (v: number) => formatPercent(v, { digits: 0 });

function PointTooltip({ active, payload }: TooltipContentProps<number, string>) {
  const p = active ? (payload?.[0]?.payload as ParetoPoint | undefined) : undefined;
  if (!p || p.sku === null) return null;
  return (
    <div className="max-w-64 rounded-md border bg-background px-3 py-2 text-xs shadow-md">
      <p className="mb-1 text-muted-foreground">
        {p.rank}. {p.name} ({p.sku}) · klasa {p.abcClass}
      </p>
      <p className="flex items-center gap-2">
        <span className="h-0.5 w-3 rounded-full bg-[var(--viz-series-1)]" aria-hidden />
        <span className="font-semibold tabular-nums">{formatPercent(p.y)}</span>
        <span className="text-muted-foreground">przychodu</span>
      </p>
      <p className="mt-0.5 pl-5 text-muted-foreground tabular-nums">
        z {formatPercent(p.x)} produktów ({p.rank} najlepszych)
      </p>
    </div>
  );
}

/**
 * Pareto curve of the ABC analysis: products in ranking order on X (as a share of all
 * products), cumulative revenue share on Y, with the 80% / 95% class thresholds.
 */
export function ParetoChart({ rows }: { rows: ProductRow[] }) {
  const data = paretoPoints(rows);
  const top = topShare(rows);
  const boundaries = classBoundaries(rows);
  // Every 10% of products, for the table view (the curve itself has one point per product).
  const deciles = TICKS.concat([0.1, 0.3, 0.5, 0.7, 0.9])
    .filter((f) => f > 0)
    .sort((a, b) => a - b)
    .map((f) => ({ fraction: f, ...topShare(rows, f)! }));

  return (
    <figure className="flex flex-col gap-3">
      <figcaption className="flex flex-col gap-1">
        <span className="font-medium">Wykres Pareto</span>
        {top && (
          <span className="text-sm text-muted-foreground">
            20% produktów ({top.products}) daje {formatPercent(top.share)} przychodu.
          </span>
        )}
      </figcaption>

      <ChartContainer config={config} className="aspect-auto h-64 w-full sm:h-80">
        <LineChart data={data} margin={{ top: 16, right: 16, left: 0, bottom: 4 }}>
          <CartesianGrid stroke="var(--viz-grid)" />
          <XAxis
            dataKey="x"
            type="number"
            domain={[0, 1]}
            ticks={TICKS}
            tickFormatter={pct0}
            tickLine={false}
            axisLine={{ stroke: "var(--viz-grid)" }}
            tick={{ fill: "var(--viz-axis)", fontSize: 12 }}
            label={{ value: "% produktów (od największego przychodu)", position: "insideBottom", offset: -2, fill: "var(--viz-axis)", fontSize: 12 }}
            height={40}
          />
          <YAxis
            type="number"
            domain={[0, 1]}
            ticks={TICKS}
            tickFormatter={pct0}
            width={48}
            tickLine={false}
            axisLine={false}
            tick={{ fill: "var(--viz-axis)", fontSize: 12 }}
          />
          {([ABC_THRESHOLDS.A, ABC_THRESHOLDS.B] as const).map((y) => (
            <ReferenceLine
              key={y}
              y={y}
              stroke="var(--viz-axis)"
              strokeDasharray="4 4"
              label={{ value: pct0(y), position: "insideTopLeft", fill: "var(--viz-axis)", fontSize: 12 }}
            />
          ))}
          {boundaries.map((b) => (
            <ReferenceLine
              key={b.abcClass}
              x={b.x}
              stroke="var(--viz-axis)"
              strokeDasharray="2 4"
              label={{ value: `koniec ${b.abcClass}`, position: "insideBottomLeft", fill: "var(--viz-axis)", fontSize: 12 }}
            />
          ))}
          <Tooltip
            cursor={{ stroke: "var(--viz-axis)", strokeWidth: 1 }}
            content={(props) => <PointTooltip {...(props as TooltipContentProps<number, string>)} />}
          />
          <Line
            dataKey="y"
            type="linear"
            stroke="var(--color-y)"
            strokeWidth={2}
            dot={false}
            activeDot={{ r: 4, strokeWidth: 2, stroke: "var(--background)" }}
            isAnimationActive={false}
          />
        </LineChart>
      </ChartContainer>

      <p className="text-xs text-muted-foreground">
        Linie przerywane poziome: progi klas (80% i 95% przychodu). Pionowe: miejsce, w którym kończy się klasa A i B.
      </p>

      <details className="text-sm">
        <summary className="cursor-pointer text-muted-foreground hover:text-foreground">Pokaż dane w tabeli</summary>
        <div className="mt-2 overflow-auto rounded-lg border">
          <table className="w-full text-left">
            <caption className="sr-only">Skumulowany udział w przychodzie wg udziału produktów</caption>
            <thead>
              <tr className="border-b">
                <th className="px-3 py-2 font-medium">Najlepsze produkty</th>
                <th className="px-3 py-2 text-right font-medium">Liczba produktów</th>
                <th className="px-3 py-2 text-right font-medium">Udział w przychodzie</th>
              </tr>
            </thead>
            <tbody>
              {deciles.map((d) => (
                <tr key={d.fraction} className="border-b last:border-0">
                  <td className="px-3 py-1.5">{pct0(d.fraction)}</td>
                  <td className="px-3 py-1.5 text-right tabular-nums">{d.products}</td>
                  <td className="px-3 py-1.5 text-right tabular-nums">{formatPercent(d.share)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </details>
    </figure>
  );
}
