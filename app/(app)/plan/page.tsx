import { InfoIcon } from "lucide-react";
import type { Metadata } from "next";
import { Suspense } from "react";

import { EmptyState, PageHeader } from "@/components/data/states";
import { PlanMatrix } from "@/components/plan/plan-matrix";
import { PlanNetworkTile } from "@/components/plan/plan-network";
import { RegionTable, StoreTable } from "@/components/plan/plan-tables";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Skeleton } from "@/components/ui/skeleton";
import { getFilterContext } from "@/lib/data/filter-context";
import { getPlanRows } from "@/lib/data/plan";
import { parseFilters } from "@/lib/filters";
import { formatDate } from "@/lib/format";
import { buildPlanView, formatMonthLong, fullMonths } from "@/lib/plan";

export const metadata: Metadata = { title: "Plan vs wykonanie | Wisła · demo BI" };

function PlanSkeleton() {
  return (
    <div className="flex flex-col gap-6" role="status" aria-label="Ładowanie realizacji planu">
      <Skeleton className="h-28 w-full" />
      <Skeleton className="h-96 w-full" />
    </div>
  );
}

function Section({ id, title, description, children }: { id: string; title: string; description?: string; children: React.ReactNode }) {
  return (
    <section aria-labelledby={id} className="flex flex-col gap-3">
      <div className="flex flex-col gap-0.5">
        <h2 id={id} className="text-lg font-semibold tracking-tight">
          {title}
        </h2>
        {description && <p className="text-sm text-muted-foreground">{description}</p>}
      </div>
      {children}
    </section>
  );
}

async function PlanView({ searchParams }: { searchParams: PageProps<"/plan">["searchParams"] }) {
  const context = await getFilterContext();
  if (!context) return <EmptyState message="Brak danych: najpierw zaimportuj dane." />;

  const filters = parseFilters(await searchParams, context.range, context.options);
  const selected = `${formatDate(filters.from)} – ${formatDate(filters.to)}`;
  const months = fullMonths(filters.from, filters.to);
  if (!months) {
    return (
      <EmptyState
        message={`Wybrany okres (${selected}) nie obejmuje żadnego pełnego miesiąca, a plan jest ustalany na całe miesiące. Wybierz okres obejmujący co najmniej jeden pełny miesiąc.`}
      />
    );
  }

  const view = buildPlanView(await getPlanRows(filters));
  const period =
    months.count === 1
      ? formatMonthLong(months.first)
      : `${formatMonthLong(months.first)} – ${formatMonthLong(months.last)}`;
  const trimmed = months.first !== filters.from || months.end !== filters.to;

  return (
    <div className="flex flex-col gap-8">
      <div className="flex flex-col gap-2">
        <p className="text-sm text-muted-foreground">
          Pełne miesiące: {period}
          {trimmed && ` (wybrany okres ${selected}; niepełne miesiące na jego krańcach pominięto)`}
        </p>
        {filters.category !== null && (
          <Alert>
            <InfoIcon aria-hidden />
            <AlertDescription>
              Filtr kategorii nie dotyczy budżetów sklepów: plan jest ustalany na cały sklep, więc plan i wykonanie
              obejmują wszystkie kategorie. Kanał i województwo działają.
            </AlertDescription>
          </Alert>
        )}
      </div>

      {!view.network ? (
        <EmptyState message={`Brak planu i sprzedaży dla wybranych filtrów w okresie ${period}. Zmień kanał lub województwo.`} />
      ) : (
        <>
          <PlanNetworkTile network={view.network} period={period} />
          <Section
            id="plan-matrix"
            title="Sklepy × miesiące"
            description="Realizacja planu (wykonanie / plan) w każdym miesiącu. Najedź na komórkę, aby zobaczyć kwoty."
          >
            <PlanMatrix view={view} period={period} />
          </Section>
          <Section id="plan-regions" title="Województwa" description="Sklep internetowy jako osobna grupa (nie ma województwa).">
            <RegionTable regions={view.regions} />
          </Section>
          <Section id="plan-stores" title="Sklepy" description="Za cały okres; kliknij nagłówek, aby posortować.">
            <StoreTable stores={view.stores} />
          </Section>
        </>
      )}
    </div>
  );
}

export default function PlanPage({ searchParams }: PageProps<"/plan">) {
  return (
    <>
      <PageHeader
        title="Plan vs wykonanie"
        description="Realizacja budżetu sprzedaży sklepów (kwoty netto). Filtr kategorii nie dotyczy budżetów."
      />
      <Suspense fallback={<PlanSkeleton />}>
        <PlanView searchParams={searchParams} />
      </Suspense>
    </>
  );
}
