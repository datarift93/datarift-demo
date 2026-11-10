import "server-only";

import { getCurrentUser } from "@/lib/auth";
import type { Filters } from "@/lib/filters";
import type { AbcClass, AbcSummaryRow, ProductRow } from "@/lib/products";
import { createClient } from "@/lib/supabase/server";

export type ProductsData = { ranking: ProductRow[]; summary: AbcSummaryRow[] };

type RankingRow = {
  rank: number;
  sku: string;
  product_name: string;
  category_code: string;
  category_name: string;
  purchase_currency: "PLN" | "EUR";
  revenue: number;
  margin: number;
  margin_pct: number | null;
  units: number;
  orders: number;
  revenue_share: number | null;
  cum_share: number | null;
  abc_class: AbcClass;
};

type SummaryRow = {
  abc_class: AbcClass;
  products: number;
  revenue: number;
  revenue_share: number | null;
  product_share: number | null;
};

// PostgREST returns numeric as number (or string for very large values); normalize.
const num = (v: unknown): number => (typeof v === "number" ? v : Number(v));
const numOrNull = (v: unknown): number | null => (v === null || v === undefined ? null : num(v));

// The org has ~400 products; the Data API caps responses at 1000 rows, so a full ranking
// beyond that would be cut silently. Fail loudly instead of showing a partial ABC split.
const MAX_ROWS = 1000;

/**
 * Product ranking with ABC classes and the per-class summary for the filters. Both come
 * from SECURITY DEFINER functions over analytics.sales_product_store_day (migration
 * *_products_analytics), scoped to the user's active org.
 */
export async function getProductsData(filters: Filters): Promise<ProductsData> {
  const [supabase, user] = await Promise.all([createClient(), getCurrentUser()]);
  const args = {
    p_org_id: user.orgId,
    p_from: filters.from,
    p_to: filters.to,
    p_channel: filters.channel,
    p_region_code: filters.region,
    p_category_code: filters.category,
  };
  const [ranking, summary] = await Promise.all([
    supabase.rpc("product_ranking", args, { count: "exact" }).range(0, MAX_ROWS - 1),
    supabase.rpc("product_abc_summary", args),
  ]);
  if (ranking.error) throw new Error(`Nie udało się wczytać rankingu produktów: ${ranking.error.message}`);
  if (summary.error) throw new Error(`Nie udało się policzyć analizy ABC: ${summary.error.message}`);
  if ((ranking.count ?? 0) > MAX_ROWS) {
    throw new Error(`Ranking ma ${ranking.count} produktów, więcej niż ${MAX_ROWS} obsługiwanych w widoku`);
  }

  return {
    ranking: (ranking.data as RankingRow[]).map((r) => ({
      rank: num(r.rank),
      sku: r.sku,
      name: r.product_name,
      categoryCode: r.category_code,
      categoryName: r.category_name,
      currency: r.purchase_currency,
      revenue: num(r.revenue),
      margin: num(r.margin),
      marginPct: numOrNull(r.margin_pct),
      units: num(r.units),
      orders: num(r.orders),
      revenueShare: numOrNull(r.revenue_share),
      cumShare: numOrNull(r.cum_share),
      abcClass: r.abc_class,
    })),
    summary: (summary.data as SummaryRow[]).map((r) => ({
      abcClass: r.abc_class,
      products: num(r.products),
      revenue: num(r.revenue),
      revenueShare: numOrNull(r.revenue_share),
      productShare: numOrNull(r.product_share),
    })),
  };
}
