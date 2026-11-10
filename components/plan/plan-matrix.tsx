import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { formatPercent, formatPLN } from "@/lib/format";
import { formatMonth, formatMonthLong, planStatus, type PlanFigures, type PlanView } from "@/lib/plan";
import { cn } from "@/lib/utils";

import { PlanLegend, Realization, STATUS } from "./plan-status";

function describe(name: string, when: string, f: PlanFigures): string {
  const parts = [
    `${name}, ${when}`,
    `plan ${formatPLN(f.plan, { whole: true })}`,
    `wykonanie ${formatPLN(f.actual, { whole: true })}`,
    `odchylenie ${formatPLN(f.deviation, { whole: true })}`,
  ];
  if (f.realization !== null) parts.push(`realizacja ${formatPercent(f.realization)}`);
  return parts.join(" · ");
}

function Cell({ figures, name, when, strong }: { figures?: PlanFigures; name: string; when: string; strong?: boolean }) {
  if (!figures) {
    return (
      <TableCell className="text-right text-muted-foreground" title={`${name}, ${when}: brak planu i sprzedaży`}>
        –
      </TableCell>
    );
  }
  const status = planStatus(figures.realization);
  return (
    <TableCell
      className={cn("text-right", status && STATUS[status].cell, strong && "font-semibold")}
      title={describe(name, when, figures)}
    >
      <Realization value={figures.realization} className="justify-end" />
    </TableCell>
  );
}

const STICKY = "sticky left-0 z-10 bg-background";

/**
 * Store x month table of realization, colored by status (< 90%, 90-100%, >= 100%) with an
 * icon in every cell, so the status never depends on color alone. Hovering a cell shows
 * plan, actual and deviation. Scrolls horizontally with the store column pinned.
 */
export function PlanMatrix({ view, period }: { view: PlanView; period: string }) {
  return (
    <div className="flex flex-col gap-3">
      <PlanLegend />
      <div className="overflow-x-auto rounded-lg border">
        <Table>
          <caption className="sr-only">Realizacja planu: sklepy według miesięcy</caption>
          <TableHeader>
            <TableRow>
              <TableHead className={STICKY}>Sklep</TableHead>
              {view.months.map((m) => (
                <TableHead key={m} className="text-right whitespace-nowrap">
                  {formatMonth(m)}
                </TableHead>
              ))}
              <TableHead className="text-right">Razem</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {view.stores.map((s) => (
              <TableRow key={s.storeCode}>
                <TableHead scope="row" className={cn(STICKY, "font-normal")}>
                  <span className="flex flex-col py-1">
                    <span className="font-medium text-foreground">{s.storeName}</span>
                    <span className="text-xs text-muted-foreground">
                      {s.regionCode === null ? "kanał online" : s.regionName}
                    </span>
                  </span>
                </TableHead>
                {view.months.map((m) => (
                  <Cell key={m} figures={s.months[m]} name={s.storeName} when={formatMonthLong(m)} />
                ))}
                <Cell figures={s} name={s.storeName} when={period} strong />
              </TableRow>
            ))}
          </TableBody>
          {view.network && (
            <TableFooter>
              <TableRow>
                <TableHead scope="row" className={cn(STICKY, "bg-muted font-medium text-foreground")}>
                  Cała sieć
                </TableHead>
                {view.months.map((m) => (
                  <Cell key={m} figures={view.networkMonths[m]} name="Cała sieć" when={formatMonthLong(m)} />
                ))}
                <Cell figures={view.network} name="Cała sieć" when={period} strong />
              </TableRow>
            </TableFooter>
          )}
        </Table>
      </div>
    </div>
  );
}
