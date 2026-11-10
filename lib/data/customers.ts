import "server-only";

import { getCurrentUser } from "@/lib/auth";
import type { CohortCell, ScoreBand, SegmentName, SegmentRow } from "@/lib/customers";
import type { Filters } from "@/lib/filters";
import { createClient } from "@/lib/supabase/server";

export type CustomersData = {
  segments: SegmentRow[];
  scores: ScoreBand[];
  cohorts: CohortCell[];
};

type SegmentDbRow = {
  segment: SegmentName;
  customers: number;
  revenue: number;
  avg_recency_days: number | null;
  avg_frequency: number | null;
  share_customers: number;
  share_revenue: number;
};

type ScoreDbRow = { dimension: ScoreBand["dimension"]; score: number; customers: number; min_value: number; max_value: number };

type CohortDbRow = {
  cohort_month: string;
  months_since: number;
  cohort_size: number;
  active_customers: number;
  retention: number;
};

// PostgREST returns numeric as number (or string for very large values); normalize.
const num = (v: unknown): number => (typeof v === "number" ? v : Number(v));
const numOrNull = (v: unknown): number | null => (v === null || v === undefined ? null : num(v));

/**
 * RFM segments (6 rows), score bands (15 rows) and the cohort matrix (<= 24 x 24 cells)
 * for the user's active org. All three are aggregates from SECURITY DEFINER functions
 * (migration *_customers_analytics); no per-customer rows leave the database. The
 * category filter is not sent: it does not apply to customers.
 */
export async function getCustomersData(filters: Filters): Promise<CustomersData> {
  const [supabase, user] = await Promise.all([createClient(), getCurrentUser()]);
  const args = {
    p_org_id: user.orgId,
    p_from: filters.from,
    p_to: filters.to,
    p_channel: filters.channel,
    p_region_code: filters.region,
  };
  const [segments, scores, cohorts] = await Promise.all([
    supabase.rpc("customer_rfm_segments", args),
    supabase.rpc("customer_rfm_scores", args),
    supabase.rpc("customer_cohorts", args),
  ]);
  if (segments.error) throw new Error(`Nie udało się policzyć segmentów: ${segments.error.message}`);
  if (scores.error) throw new Error(`Nie udało się policzyć ocen RFM: ${scores.error.message}`);
  if (cohorts.error) throw new Error(`Nie udało się policzyć kohort: ${cohorts.error.message}`);

  return {
    segments: (segments.data as SegmentDbRow[]).map((r) => ({
      segment: r.segment,
      customers: num(r.customers),
      revenue: num(r.revenue),
      avgRecencyDays: numOrNull(r.avg_recency_days),
      avgFrequency: numOrNull(r.avg_frequency),
      shareCustomers: num(r.share_customers),
      shareRevenue: num(r.share_revenue),
    })),
    scores: (scores.data as ScoreDbRow[]).map((r) => ({
      dimension: r.dimension,
      score: num(r.score),
      customers: num(r.customers),
      min: num(r.min_value),
      max: num(r.max_value),
    })),
    cohorts: (cohorts.data as CohortDbRow[]).map((r) => ({
      cohortMonth: r.cohort_month,
      monthsSince: num(r.months_since),
      cohortSize: num(r.cohort_size),
      active: num(r.active_customers),
      retention: num(r.retention),
    })),
  };
}
