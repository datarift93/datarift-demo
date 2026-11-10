import { InfoIcon } from "lucide-react";
import type { Metadata } from "next";
import { Suspense } from "react";

import { CohortHeatmap } from "@/components/customers/cohort-heatmap";
import { ScoreBands, SegmentTable, SegmentTiles } from "@/components/customers/segments";
import { EmptyState, PageHeader } from "@/components/data/states";
import { Skeleton } from "@/components/ui/skeleton";
import { totalCustomers } from "@/lib/customers";
import { getCustomersData } from "@/lib/data/customers";
import { getFilterContext } from "@/lib/data/filter-context";
import { addDays, parseFilters } from "@/lib/filters";
import { formatDate } from "@/lib/format";

export const metadata: Metadata = { title: "Klienci | Wisła · demo BI" };

function CustomersSkeleton() {
  return (
    <div className="flex flex-col gap-6" role="status" aria-label="Ładowanie danych klientów">
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
        {Array.from({ length: 6 }, (_, i) => (
          <Skeleton key={i} className="h-44 w-full" />
        ))}
      </div>
      <Skeleton className="h-96 w-full" />
    </div>
  );
}

async function CustomersView({ searchParams }: { searchParams: PageProps<"/klienci">["searchParams"] }) {
  const context = await getFilterContext();
  if (!context) return <EmptyState message="Brak danych: najpierw zaimportuj dane." />;

  const filters = parseFilters(await searchParams, context.range, context.options);
  const data = await getCustomersData(filters);
  const categoryName = filters.category
    ? (context.categories.find((c) => c.code === filters.category)?.name ?? filters.category)
    : null;
  const customers = totalCustomers(data.segments);

  return (
    <div className="flex flex-col gap-8">
      <div className="flex items-start gap-2 rounded-lg border bg-muted/40 px-3 py-2 text-sm">
        <InfoIcon className="mt-0.5 size-4 shrink-0 text-muted-foreground" aria-hidden />
        <p>
          {categoryName ? (
            <>
              <span className="font-medium">Filtr kategorii „{categoryName}” nie dotyczy tego widoku</span>: segmenty
              i kohorty opisują klientów, nie produkty.{" "}
            </>
          ) : (
            <>Filtr kategorii nie dotyczy tego widoku: segmenty i kohorty opisują klientów, nie produkty. </>
          )}
          <span className="text-muted-foreground">
            Tylko klienci z kartą lub kontem (bez anonimowych zakupów w sklepach). Województwo = województwo klienta,
            kanał = kanał zamówienia.
          </span>
        </p>
      </div>

      <section className="flex flex-col gap-4" aria-labelledby="rfm">
        <div className="flex flex-col gap-1">
          <h2 id="rfm" className="text-lg font-semibold">
            Segmenty RFM na dzień {formatDate(filters.to)}
          </h2>
          <p className="text-sm text-muted-foreground">
            Recency (dni od ostatniego zakupu), Frequency i Monetary (zamówienia i przychód netto w 12 miesiącach{" "}
            {formatDate(addDays(filters.to, -364))} – {formatDate(filters.to)}), każda ocena 1–5 (kwintyle). Liczone na
            koniec wybranego okresu dla wszystkich klientów z zakupem do tego dnia.
          </p>
        </div>
        {customers === 0 ? (
          <EmptyState message="Brak klientów z zakupem dla wybranych filtrów. Zmień kanał, województwo lub okres." />
        ) : (
          <>
            <SegmentTiles rows={data.segments} />
            <SegmentTable rows={data.segments} />
            <details className="text-sm">
              <summary className="cursor-pointer text-muted-foreground hover:text-foreground">
                Jak liczymy oceny R, F i M
              </summary>
              <div className="mt-3 flex flex-col gap-3">
                <p className="text-muted-foreground">
                  Klienci są dzieleni na pięć równych grup w każdym wymiarze (5 = najlepsza). Segment to pierwsza
                  pasująca reguła w kolejności kafelków. Zakresy dla bieżących filtrów:
                </p>
                <ScoreBands bands={data.scores} />
              </div>
            </details>
          </>
        )}
      </section>

      <section className="flex flex-col gap-4" aria-labelledby="kohorty">
        <div className="flex flex-col gap-1">
          <h2 id="kohorty" className="text-lg font-semibold">
            Kohorty retencji
          </h2>
          <p className="text-sm text-muted-foreground">
            Kohorta = miesiąc pierwszego zakupu klienta (w całej historii), dla klientów, których pierwszy zakup
            przypada w okresie {formatDate(filters.from)} – {formatDate(filters.to)}. Retencję śledzimy do ostatniego
            pełnego miesiąca danych.
          </p>
        </div>
        {data.cohorts.length === 0 ? (
          <EmptyState message="Brak nowych klientów w wybranym okresie. Wybierz dłuższy okres, np. „Cały okres”." />
        ) : (
          <div className="rounded-lg border p-4">
            <CohortHeatmap cells={data.cohorts} />
          </div>
        )}
      </section>
    </div>
  );
}

export default function CustomersPage({ searchParams }: PageProps<"/klienci">) {
  return (
    <>
      <PageHeader title="Klienci" description="Segmentacja RFM i kohorty retencji (kwoty netto)" />
      <Suspense fallback={<CustomersSkeleton />}>
        <CustomersView searchParams={searchParams} />
      </Suspense>
    </>
  );
}
