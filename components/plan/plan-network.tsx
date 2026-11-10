import { formatPLN } from "@/lib/format";
import type { PlanFigures } from "@/lib/plan";

import { Realization } from "./plan-status";

/** Network summary: plan, actual, realization and deviation for the whole period. */
export function PlanNetworkTile({ network, period }: { network: PlanFigures; period: string }) {
  const deviation = formatPLN(network.deviation, { whole: true });
  return (
    <section aria-labelledby="plan-network" className="rounded-lg border p-4">
      <h2 id="plan-network" className="text-sm text-muted-foreground">
        Cała sieć · {period}
      </h2>
      <dl className="mt-3 grid grid-cols-2 gap-4 lg:grid-cols-4">
        <div className="flex flex-col gap-1">
          <dt className="text-sm text-muted-foreground">Realizacja</dt>
          <dd className="text-2xl font-semibold tracking-tight">
            <Realization value={network.realization} className="[&_svg]:size-5" />
          </dd>
        </div>
        <div className="flex flex-col gap-1">
          <dt className="text-sm text-muted-foreground">Plan</dt>
          <dd className="text-2xl font-semibold tracking-tight">{formatPLN(network.plan, { whole: true })}</dd>
        </div>
        <div className="flex flex-col gap-1">
          <dt className="text-sm text-muted-foreground">Wykonanie</dt>
          <dd className="text-2xl font-semibold tracking-tight">{formatPLN(network.actual, { whole: true })}</dd>
        </div>
        <div className="flex flex-col gap-1">
          <dt className="text-sm text-muted-foreground">Odchylenie</dt>
          <dd className="text-2xl font-semibold tracking-tight">
            {network.deviation > 0 ? `+${deviation}` : deviation}
          </dd>
        </div>
      </dl>
    </section>
  );
}
