import { formatInteger, formatPercent, formatPLN } from "@/lib/format";
import { ABC_INFO, ABC_RULE_NOTE, productsLabel, type AbcSummaryRow } from "@/lib/products";

/** One tile per ABC class: products, share of products, share of revenue, and the rule. */
export function AbcTiles({ summary }: { summary: AbcSummaryRow[] }) {
  return (
    <section aria-labelledby="abc-heading" className="flex flex-col gap-2">
      <h2 id="abc-heading" className="font-medium">
        Analiza ABC
      </h2>
      <dl className="grid gap-3 sm:grid-cols-3">
        {summary.map((s) => (
          <div key={s.abcClass} className="flex flex-col gap-1.5 rounded-lg border p-4">
            <dt className="flex items-center gap-2 text-sm text-muted-foreground">
              <span
                className="inline-flex size-6 items-center justify-center rounded-md border font-semibold text-foreground"
                aria-hidden
              >
                {s.abcClass}
              </span>
              {ABC_INFO[s.abcClass].title}
            </dt>
            <dd className="flex flex-col gap-1">
              <span className="text-2xl font-semibold tracking-tight">
                {s.revenueShare === null ? "–" : formatPercent(s.revenueShare)}
                <span className="ml-1.5 text-sm font-normal text-muted-foreground">przychodu</span>
              </span>
              <span className="text-sm">
                {formatInteger(s.products)} {productsLabel(s.products)}
                {s.productShare !== null && (
                  <span className="text-muted-foreground"> ({formatPercent(s.productShare)} produktów)</span>
                )}
              </span>
              <span className="text-sm text-muted-foreground tabular-nums">{formatPLN(s.revenue, { whole: true })}</span>
              <span className="text-xs text-muted-foreground">{ABC_INFO[s.abcClass].rule}</span>
            </dd>
          </div>
        ))}
      </dl>
      <p className="text-xs text-muted-foreground">{ABC_RULE_NOTE}</p>
    </section>
  );
}
