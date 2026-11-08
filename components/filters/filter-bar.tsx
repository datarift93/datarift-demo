import { getFilterContext } from "@/lib/data/filter-context";

import { FilterControls } from "./filter-controls";

/** Loads the filter options for the user's org, then renders the URL-driven controls. */
export async function FilterBar() {
  const context = await getFilterContext();
  if (!context) {
    return <p className="text-sm text-muted-foreground">Brak danych: najpierw zaimportuj dane.</p>;
  }
  return <FilterControls context={context} />;
}

export function FilterBarSkeleton() {
  return <div className="h-9 w-full max-w-3xl animate-pulse rounded-md bg-muted" aria-hidden />;
}
