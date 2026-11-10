import type { Metadata } from "next";
import { Suspense } from "react";

import { EmptyState, PageHeader, TableSkeleton } from "@/components/data/states";
import { AbcTiles } from "@/components/products/abc-tiles";
import { ParetoChart } from "@/components/products/pareto-chart";
import { ProductTable } from "@/components/products/product-table";
import { Skeleton } from "@/components/ui/skeleton";
import { getFilterContext } from "@/lib/data/filter-context";
import { getProductsData } from "@/lib/data/products";
import { parseFilters } from "@/lib/filters";
import { formatDate, formatInteger } from "@/lib/format";
import { productsLabel } from "@/lib/products";

export const metadata: Metadata = { title: "Produkty | Wisła · demo BI" };

function ProductsSkeleton() {
  return (
    <div className="flex flex-col gap-6" role="status" aria-label="Ładowanie produktów">
      <div className="grid gap-3 sm:grid-cols-3">
        {Array.from({ length: 3 }, (_, i) => (
          <Skeleton key={i} className="h-36 w-full" />
        ))}
      </div>
      <Skeleton className="h-80 w-full" />
      <TableSkeleton />
    </div>
  );
}

async function ProductsView({ searchParams }: { searchParams: PageProps<"/produkty">["searchParams"] }) {
  const context = await getFilterContext();
  if (!context) return <EmptyState message="Brak danych: najpierw zaimportuj dane." />;

  const filters = parseFilters(await searchParams, context.range, context.options);
  const { ranking, summary } = await getProductsData(filters);
  const period = `${formatDate(filters.from)} – ${formatDate(filters.to)}`;

  if (ranking.length === 0) {
    return (
      <EmptyState
        message={`Brak sprzedaży produktów dla wybranych filtrów w okresie ${period}. Zmień okres, kanał, województwo lub kategorię.`}
      />
    );
  }

  return (
    <div className="flex flex-col gap-6">
      <p className="text-sm text-muted-foreground">
        Okres: {period} · {formatInteger(ranking.length)} {productsLabel(ranking.length)} ze sprzedażą
      </p>
      <AbcTiles summary={summary} />
      <div className="rounded-lg border p-4">
        <ParetoChart rows={ranking} />
      </div>
      <section aria-labelledby="ranking-heading" className="flex flex-col gap-2">
        <h2 id="ranking-heading" className="font-medium">
          Ranking produktów
        </h2>
        <p className="text-xs text-muted-foreground">
          Kliknij nagłówek kolumny, aby posortować. Marża = przychód netto minus koszt zakupu (średnia ważona z
          zakupów z 90 dni przed sprzedażą; koszt w EUR przeliczony po kursie NBP z dnia zakupu).
        </p>
        <ProductTable rows={ranking} />
      </section>
    </div>
  );
}

export default function ProductsPage({ searchParams }: PageProps<"/produkty">) {
  return (
    <>
      <PageHeader title="Produkty" description="Ranking, analiza ABC i marża na produkcie (kwoty netto)" />
      <Suspense fallback={<ProductsSkeleton />}>
        <ProductsView searchParams={searchParams} />
      </Suspense>
    </>
  );
}
