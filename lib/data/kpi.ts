import "server-only";

import { getCurrentUser } from "@/lib/auth";
import type { Filters } from "@/lib/filters";
import type { Grain, PeriodTotals } from "@/lib/kpi";
import { createClient } from "@/lib/supabase/server";

export type SeriesPoint = { bucket: string; revenue: number; margin: number; orders: number };

export type KpiData = {
  current: PeriodTotals;
  previous: PeriodTotals;
  firstDay: string | null;
  grain: Grain;
  series: SeriesPoint[];
};

type SummaryRow = {
  period: "current" | "previous";
  date_from: string;
  date_to: string;
  revenue: number;
  margin: number;
  orders: number;
  units: number;
  first_day: string | null;
};

type SeriesRow = { grain: Grain; bucket: string; revenue: number; margin: number; orders: number };

// PostgREST returns numeric as number (or string for very large values); normalize.
const num = (v: unknown): number => (typeof v === "number" ? v : Number(v));

function totals(r: SummaryRow): PeriodTotals {
  return {
    dateFrom: r.date_from,
    dateTo: r.date_to,
    revenue: num(r.revenue),
    margin: num(r.margin),
    orders: num(r.orders),
    units: num(r.units),
  };
}

/**
 * KPI totals for the period and the previous one, plus revenue over time. Both come
 * from SECURITY DEFINER functions over materialized views (migration *_kpi_analytics),
 * scoped to the user's active org.
 */
export async function getKpiData(filters: Filters): Promise<KpiData> {
  const [supabase, user] = await Promise.all([createClient(), getCurrentUser()]);
  const args = {
    p_org_id: user.orgId,
    p_from: filters.from,
    p_to: filters.to,
    p_channel: filters.channel,
    p_region_code: filters.region,
    p_category_code: filters.category,
  };
  const [summary, series] = await Promise.all([
    supabase.rpc("kpi_summary", args),
    supabase.rpc("kpi_timeseries", args),
  ]);
  if (summary.error) throw new Error(`Nie udało się policzyć KPI: ${summary.error.message}`);
  if (series.error) throw new Error(`Nie udało się wczytać wykresu: ${series.error.message}`);

  const rows = summary.data as SummaryRow[];
  const current = rows.find((r) => r.period === "current");
  const previous = rows.find((r) => r.period === "previous");
  if (!current || !previous) throw new Error("Niepełna odpowiedź funkcji KPI");

  const points = series.data as SeriesRow[];
  return {
    current: totals(current),
    previous: totals(previous),
    firstDay: current.first_day,
    grain: points[0]?.grain ?? "day",
    series: points.map((p) => ({
      bucket: p.bucket,
      revenue: num(p.revenue),
      margin: num(p.margin),
      orders: num(p.orders),
    })),
  };
}
