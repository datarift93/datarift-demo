import { CircleAlertIcon, CircleCheckIcon, CircleXIcon } from "lucide-react";

import { formatPercent } from "@/lib/format";
import { planStatus, type PlanStatus } from "@/lib/plan";
import { cn } from "@/lib/utils";

// Status palette (dataviz skill, fixed in both themes): critical / warning / good. The
// color only reinforces the icon and the label; text stays in the normal ink.
export const STATUS: Record<
  PlanStatus,
  { label: string; short: string; icon: typeof CircleXIcon; iconClass: string; cell: string }
> = {
  below: {
    label: "Poniżej 90% planu",
    short: "< 90%",
    icon: CircleXIcon,
    iconClass: "text-[#d03b3b]",
    cell: "bg-[#d03b3b]/15",
  },
  near: {
    label: "90–100% planu",
    short: "90–100%",
    icon: CircleAlertIcon,
    iconClass: "text-[#b07800] dark:text-[#fab219]",
    cell: "bg-[#fab219]/20",
  },
  met: {
    label: "Plan wykonany (≥ 100%)",
    short: "≥ 100%",
    icon: CircleCheckIcon,
    iconClass: "text-[#0a850a] dark:text-[#0ca30c]",
    cell: "bg-[#0ca30c]/15",
  },
};

/** Realization with its status icon; the status is also spelled out for screen readers. */
export function Realization({ value, className }: { value: number | null; className?: string }) {
  const status = planStatus(value);
  if (value === null || status === null) {
    return (
      <span className={cn("text-muted-foreground", className)} title="Brak planu na ten okres">
        –<span className="sr-only">brak planu</span>
      </span>
    );
  }
  const s = STATUS[status];
  const Icon = s.icon;
  return (
    <span className={cn("inline-flex items-center gap-1 tabular-nums", className)}>
      <Icon className={cn("size-4 shrink-0", s.iconClass)} aria-hidden />
      <span className="sr-only">{s.label}:</span>
      {formatPercent(value)}
    </span>
  );
}

export function PlanLegend() {
  return (
    <ul className="flex flex-wrap items-center gap-x-4 gap-y-2 text-sm text-muted-foreground" aria-label="Legenda realizacji planu">
      {(Object.keys(STATUS) as PlanStatus[]).map((key) => {
        const s = STATUS[key];
        const Icon = s.icon;
        return (
          <li key={key} className="inline-flex items-center gap-1.5">
            <span className={cn("inline-flex size-6 items-center justify-center rounded", s.cell)}>
              <Icon className={cn("size-4", s.iconClass)} aria-hidden />
            </span>
            {s.label}
          </li>
        );
      })}
      <li className="inline-flex items-center gap-1.5">
        <span className="inline-flex size-6 items-center justify-center rounded border">–</span>
        Brak planu
      </li>
    </ul>
  );
}
