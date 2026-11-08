import type { Metadata } from "next";
import { Suspense } from "react";

import { EmptyState, PageHeader } from "@/components/data/states";
import { KpiTiles } from "@/components/kpi/kpi-tiles";
import { RevenueChart } from "@/components/kpi/revenue-chart";
import { Skeleton } from "@/components/ui/skeleton";
import { getFilterContext } from "@/lib/data/filter-context";
import { getKpiData } from "@/lib/data/kpi";
import { parseFilters } from "@/lib/filters";
import { formatDate } from "@/lib/format";
import { computeKpis } from "@/lib/kpi";

export const metadata: Metadata = { title: "KPI | Wisła · demo BI" };

function KpiSkeleton() {
  return (
    <div className="flex flex-col gap-6" role="status" aria-label="Ładowanie wskaźników">
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        {Array.from({ length: 4 }, (_, i) => (
          <Skeleton key={i} className="h-32 w-full" />
        ))}
      </div>
      <Skeleton className="h-72 w-full" />
    </div>
  );
}

async function KpiView({ searchParams }: { searchParams: PageProps<"/kpi">["searchParams"] }) {
  const context = await getFilterContext();
  if (!context) return <EmptyState message="Brak danych: najpierw zaimportuj dane." />;

  const filters = parseFilters(await searchParams, context.range, context.options);
  const data = await getKpiData(filters);
  const result = computeKpis(data.current, data.previous, data.firstDay, {
    categoryFiltered: filters.category !== null,
  });
  const period = `${formatDate(filters.from)} – ${formatDate(filters.to)}`;

  if (result.empty) {
    return (
      <EmptyState
        message={`Brak sprzedaży dla wybranych filtrów w okresie ${period}. Zmień okres, kanał, województwo lub kategorię.`}
      />
    );
  }

  return (
    <div className="flex flex-col gap-6">
      <p className="text-sm text-muted-foreground">Okres: {period}</p>
      <KpiTiles result={result} />
      <div className="rounded-lg border p-4">
        <RevenueChart series={data.series} grain={data.grain} to={filters.to} />
      </div>
    </div>
  );
}

export default function KpiPage({ searchParams }: PageProps<"/kpi">) {
  return (
    <>
      <PageHeader title="KPI" description="Przychód, marża, zamówienia i średni koszyk (kwoty netto)" />
      <Suspense fallback={<KpiSkeleton />}>
        <KpiView searchParams={searchParams} />
      </Suspense>
    </>
  );
}
