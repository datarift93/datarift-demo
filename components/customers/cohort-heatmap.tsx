"use client";

import { Fragment, useState } from "react";

import {
  buildCohortMatrix,
  cohortLabel,
  cohortLabelLong,
  percentCell,
  RETENTION_BINS,
  retentionBin,
  type CohortCell,
} from "@/lib/customers";
import { formatInteger, formatPercent } from "@/lib/format";
import { cn } from "@/lib/utils";

type Hover = { cell: CohortCell; x: number; y: number };

/** Per-bin colors as CSS variables, switched by the `dark` variant (anchor flips in dark mode). */
function binStyle(retention: number): React.CSSProperties {
  const b = RETENTION_BINS[retentionBin(retention)];
  return {
    "--cell-bg": b.light,
    "--cell-fg": b.inkLight,
    "--cell-bg-dark": b.dark,
    "--cell-fg-dark": b.inkDark,
  } as React.CSSProperties;
}

const CELL = "bg-(--cell-bg) text-(--cell-fg) dark:bg-(--cell-bg-dark) dark:text-(--cell-fg-dark)";

function binLabel(i: number): string {
  const b = RETENTION_BINS[i];
  const pct = (v: number) => String(Math.round(v * 100));
  if (i === 0) return `< ${pct(b.to)}%`;
  if (b.to === Infinity) return `≥ ${pct(b.from)}%`;
  return `${pct(b.from)}–${pct(b.to)}%`;
}

function monthsLabel(k: number): string {
  if (k === 0) return "miesiąc pierwszego zakupu";
  if (k === 1) return "1 miesiąc później";
  if (k % 10 >= 2 && k % 10 <= 4 && (k % 100 < 12 || k % 100 > 14)) return `${k} miesiące później`;
  return `${k} miesięcy później`;
}

/**
 * Retention matrix: rows = cohorts (month of the first purchase), columns = months since
 * then, color = retention on a binned single-hue scale, value printed in every cell.
 * Hover shows the counts; the same numbers are in the table below for keyboard and
 * screen-reader users.
 */
export function CohortHeatmap({ cells }: { cells: CohortCell[] }) {
  const matrix = buildCohortMatrix(cells);
  const [hover, setHover] = useState<Hover | null>(null);

  function onEnter(e: React.PointerEvent<HTMLElement>, cell: CohortCell) {
    const box = e.currentTarget.getBoundingClientRect();
    const frame = e.currentTarget.closest("[data-heatmap]")?.getBoundingClientRect();
    if (!frame) return;
    setHover({ cell, x: box.left - frame.left + box.width / 2, y: box.top - frame.top });
  }

  const cols = `minmax(6.5rem, max-content) repeat(${matrix.months.length}, minmax(2.25rem, 1fr))`;

  return (
    <figure className="flex flex-col gap-3">
      <figcaption className="flex flex-wrap items-baseline justify-between gap-2">
        <span className="font-medium">Retencja kohort (% klientów, którzy kupili w danym miesiącu)</span>
        <span className="text-sm text-muted-foreground">
          {formatInteger(matrix.rows.length)} kohort ·{" "}
          {formatInteger(matrix.rows.reduce((s, r) => s + r.size, 0))} nowych klientów
        </span>
      </figcaption>

      <div className="relative" data-heatmap onPointerLeave={() => setHover(null)}>
        <div className="overflow-x-auto pb-1">
          <div
            role="img"
            aria-label="Mapa ciepła retencji kohort. Dokładne wartości w tabeli poniżej."
            className="grid min-w-max gap-0.5 text-xs"
            style={{ gridTemplateColumns: cols }}
          >
            <div className="sticky left-0 z-10 bg-background pr-2 text-muted-foreground">Kohorta</div>
            {matrix.months.map((k) => (
              <div key={k} className="text-center text-muted-foreground tabular-nums">
                {k}
              </div>
            ))}

            {matrix.rows.map((row) => (
              <Fragment key={row.cohortMonth}>
                <div className="sticky left-0 z-10 flex items-baseline justify-between gap-2 bg-background pr-2">
                  <span>{cohortLabel(row.cohortMonth)}</span>
                  <span className="text-muted-foreground tabular-nums">{formatInteger(row.size)}</span>
                </div>
                {row.cells.map((c, k) =>
                  c ? (
                    <div
                      key={k}
                      className={cn(
                        "flex h-7 items-center justify-center rounded-[3px] tabular-nums hover:outline-2 hover:outline-foreground",
                        CELL,
                      )}
                      style={binStyle(c.retention)}
                      onPointerEnter={(e) => onEnter(e, c)}
                    >
                      {percentCell(c.retention)}
                    </div>
                  ) : (
                    <div key={k} />
                  ),
                )}
              </Fragment>
            ))}

            <div className="sticky left-0 z-10 mt-1.5 bg-background pr-2 font-medium">Średnio</div>
            {matrix.average.map((v, k) => (
              <div
                key={k}
                className="mt-1.5 flex h-7 items-center justify-center rounded-[3px] border font-medium tabular-nums"
              >
                {v === null ? "" : percentCell(v)}
              </div>
            ))}
          </div>
        </div>

        {hover && (
          <div
            className="pointer-events-none absolute z-20 w-max max-w-64 rounded-md border bg-background px-3 py-2 text-xs shadow-md"
            style={{ left: hover.x, top: hover.y - 6, transform: "translate(-50%, -100%)" }}
            role="tooltip"
          >
            <p className="font-semibold tabular-nums">{formatPercent(hover.cell.retention)}</p>
            <p className="text-muted-foreground">
              Kohorta {cohortLabelLong(hover.cell.cohortMonth)}, {monthsLabel(hover.cell.monthsSince)}
            </p>
            <p className="text-muted-foreground tabular-nums">
              {formatInteger(hover.cell.active)} z {formatInteger(hover.cell.cohortSize)} klientów
            </p>
          </div>
        )}
      </div>

      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted-foreground">
        <span>Kolumny: miesiące od pierwszego zakupu. Liczba przy kohorcie: nowi klienci.</span>
        <span className="flex flex-wrap items-center gap-1" aria-label="Skala kolorów retencji">
          {RETENTION_BINS.map((b, i) => (
            <span key={i} className="flex items-center gap-1">
              <span className={cn("inline-block size-3 rounded-[2px]", CELL)} style={binStyle(b.from)} aria-hidden />
              {binLabel(i)}
            </span>
          ))}
        </span>
      </div>

      <details className="text-sm">
        <summary className="cursor-pointer text-muted-foreground hover:text-foreground">Pokaż dane w tabeli</summary>
        <div className="mt-2 max-h-96 overflow-auto rounded-lg border">
          <table className="w-full text-left">
            <caption className="sr-only">Retencja kohort: liczba i odsetek aktywnych klientów</caption>
            <thead className="sticky top-0 bg-background">
              <tr className="border-b">
                <th className="px-3 py-2 font-medium">Kohorta</th>
                <th className="px-3 py-2 text-right font-medium">Miesiąc</th>
                <th className="px-3 py-2 text-right font-medium">Nowi klienci</th>
                <th className="px-3 py-2 text-right font-medium">Aktywni</th>
                <th className="px-3 py-2 text-right font-medium">Retencja</th>
              </tr>
            </thead>
            <tbody>
              {cells.map((c) => (
                <tr key={`${c.cohortMonth}-${c.monthsSince}`} className="border-b last:border-0">
                  <td className="px-3 py-1.5">{cohortLabelLong(c.cohortMonth)}</td>
                  <td className="px-3 py-1.5 text-right tabular-nums">{c.monthsSince}</td>
                  <td className="px-3 py-1.5 text-right tabular-nums">{formatInteger(c.cohortSize)}</td>
                  <td className="px-3 py-1.5 text-right tabular-nums">{formatInteger(c.active)}</td>
                  <td className="px-3 py-1.5 text-right tabular-nums">{formatPercent(c.retention)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </details>
    </figure>
  );
}
