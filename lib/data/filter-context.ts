import "server-only";

import { getCurrentUser } from "@/lib/auth";
import type { DataRange, FilterOptions } from "@/lib/filters";
import { createClient } from "@/lib/supabase/server";

export type Option = { code: string; name: string };

export type FilterContext = {
  range: DataRange;
  regions: Option[];
  categories: Option[];
  options: FilterOptions;
};

const warsawDate = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Warsaw" });

/** YYYY-MM-DD of a timestamp in Polish local time (orders are dated by local day). */
function localDay(timestamp: string): string {
  return warsawDate.format(new Date(timestamp));
}

/**
 * What the filters can offer for the signed-in user's org: the data period and the
 * regions/categories that exist. Returns null when the org has no orders yet.
 * Reads the session: call inside <Suspense>.
 */
export async function getFilterContext(): Promise<FilterContext | null> {
  const [supabase, user] = await Promise.all([createClient(), getCurrentUser()]);
  const org = user.orgId;
  // Both ends use the (org_id, ordered_at) index. RLS already limits rows to the user's
  // orgs; the explicit org filter keeps a multi-org user's views to the active org.
  const [first, last, regions, categories] = await Promise.all([
    supabase.from("orders").select("ordered_at").eq("org_id", org).order("ordered_at", { ascending: true }).limit(1).maybeSingle(),
    supabase.from("orders").select("ordered_at").eq("org_id", org).order("ordered_at", { ascending: false }).limit(1).maybeSingle(),
    supabase.from("regions").select("region_code, name").eq("org_id", org).order("name"),
    supabase.from("categories").select("category_code, name").eq("org_id", org).order("name"),
  ]);
  for (const r of [first, last, regions, categories]) {
    if (r.error) throw new Error(`Nie udało się wczytać filtrów: ${r.error.message}`);
  }
  if (!first.data || !last.data) return null;

  const regionOptions = (regions.data ?? []).map((r) => ({ code: r.region_code, name: r.name }));
  const categoryOptions = (categories.data ?? []).map((c) => ({ code: c.category_code, name: c.name }));
  return {
    range: { min: localDay(first.data.ordered_at), max: localDay(last.data.ordered_at) },
    regions: regionOptions,
    categories: categoryOptions,
    options: {
      regions: regionOptions.map((r) => r.code),
      categories: categoryOptions.map((c) => c.code),
    },
  };
}
