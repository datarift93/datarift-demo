import { ArrowDownRightIcon, ArrowUpRightIcon, MinusIcon } from "lucide-react";

import { direction, type Kpi, type KpiResult } from "@/lib/kpi";
import { formatDate, formatInteger, formatPercent, formatPLN } from "@/lib/format";
import { cn } from "@/lib/utils";

function formatValue(k: Kpi): string {
  if (k.value === null) return "–";
  if (k.key === "orders") return formatInteger(k.value);
  if (k.key === "basket") return formatPLN(k.value);
  return formatPLN(k.value, { whole: true });
}

function formatChange(k: Kpi): string {
  if (k.change === null) return "";
  if (k.key === "orders") return `${k.change > 0 ? "+" : ""}${formatInteger(k.change)}`;
  const amount = formatPLN(k.change, { whole: k.key !== "basket" });
  return k.change > 0 ? `+${amount}` : amount;
}

const ICON = { up: ArrowUpRightIcon, down: ArrowDownRightIcon, flat: MinusIcon } as const;
const TONE = {
  up: "text-[var(--viz-delta-good)]",
  down: "text-[var(--viz-delta-bad)]",
  flat: "text-muted-foreground",
} as const;
const SPOKEN = { up: "wzrost", down: "spadek", flat: "bez zmian" } as const;

/** Signed change with an arrow; color only reinforces the arrow and sign (all four KPIs: up = good). */
function Delta({ k, previousLabel }: { k: Kpi; previousLabel: string }) {
  const dir = direction(k.changeRatio, k.change);
  if (dir === null) return null;
  const Icon = ICON[dir];
  return (
    <p className="flex flex-wrap items-center gap-x-1.5 text-sm">
      <span className={cn("inline-flex items-center gap-0.5 font-medium", TONE[dir])}>
        <Icon className="size-4" aria-hidden />
        <span className="sr-only">{SPOKEN[dir]}:</span>
        {k.changeRatio !== null ? formatPercent(k.changeRatio, { signed: true }) : formatChange(k)}
      </span>
      {k.changeRatio !== null && <span className="text-muted-foreground">({formatChange(k)})</span>}
      <span className="text-muted-foreground">vs {previousLabel}</span>
    </p>
  );
}

function MarginShare({ k }: { k: Kpi }) {
  if (k.share === null) return null;
  const pp = k.shareChange === null ? null : k.shareChange * 100;
  return (
    <p className="text-sm text-muted-foreground">
      {formatPercent(k.share)} przychodu
      {pp !== null && (
        <>
          {" "}
          ({pp > 0 ? "+" : ""}
          {new Intl.NumberFormat("pl-PL", { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(pp)} p.p.)
        </>
      )}
    </p>
  );
}

export function KpiTiles({ result }: { result: KpiResult }) {
  const prev = `${formatDate(result.previous.dateFrom)} – ${formatDate(result.previous.dateTo)}`;
  return (
    <div className="flex flex-col gap-2">
      <dl className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        {result.kpis.map((k) => (
          <div key={k.key} className="flex flex-col gap-1.5 rounded-lg border p-4">
            <dt className="text-sm text-muted-foreground">{k.label}</dt>
            <dd className="text-2xl font-semibold tracking-tight">{formatValue(k)}</dd>
            {k.key === "margin" && <MarginShare k={k} />}
            {result.comparable && <Delta k={k} previousLabel={prev} />}
          </div>
        ))}
      </dl>
      {!result.comparable && (
        <p className="text-sm text-muted-foreground">
          Brak danych do porównania: poprzedni okres ({prev}) zaczyna się przed pierwszym dniem danych.
        </p>
      )}
    </div>
  );
}
