import "server-only";

import { getCurrentUser } from "@/lib/auth";
import type { Filters } from "@/lib/filters";
import type { PlanLevel, PlanRow } from "@/lib/plan";
import { createClient } from "@/lib/supabase/server";

type Row = {
  level: PlanLevel;
  store_code: string | null;
  store_name: string | null;
  region_code: string | null;
  region_name: string | null;
  month: string | null;
  plan: number | string;
  actual: number | string;
  realization: number | string | null;
  deviation: number | string;
};

// PostgREST returns numeric as number (or string for very large values); normalize.
const num = (v: unknown): number => (typeof v === "number" ? v : Number(v));

// The Data API returns at most 1000 rows per request. Two full years for ~26 stores are
// ~1100 rows (store, region and network levels), so read in pages; the function orders
// its rows deterministically, so pages never overlap.
const PAGE_SIZE = 1000;
const MAX_PAGES = 20;

/**
 * Plan vs actual for the full months of the period at store, region and network level,
 * from the SECURITY DEFINER function plan_vs_actual (migration *_plan_analytics), scoped
 * to the user's active org. The category filter is passed on and ignored by the database.
 */
export async function getPlanRows(filters: Filters): Promise<PlanRow[]> {
  const [supabase, user] = await Promise.all([createClient(), getCurrentUser()]);
  const args = {
    p_org_id: user.orgId,
    p_from: filters.from,
    p_to: filters.to,
    p_channel: filters.channel,
    p_region_code: filters.region,
    p_category_code: filters.category,
  };

  const rows: Row[] = [];
  for (let page = 0; page < MAX_PAGES; page++) {
    const { data, error } = await supabase
      .rpc("plan_vs_actual", args)
      .range(page * PAGE_SIZE, (page + 1) * PAGE_SIZE - 1);
    if (error) throw new Error(`Nie udało się policzyć realizacji planu: ${error.message}`);
    const batch = (data ?? []) as Row[];
    rows.push(...batch);
    if (batch.length < PAGE_SIZE) break;
  }

  return rows.map((r) => ({
    level: r.level,
    storeCode: r.store_code,
    storeName: r.store_name,
    regionCode: r.region_code,
    regionName: r.region_name,
    month: r.month,
    plan: num(r.plan),
    actual: num(r.actual),
    realization: r.realization === null ? null : num(r.realization),
    deviation: num(r.deviation),
  }));
}
