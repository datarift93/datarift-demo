// Plan vs actual (F6). Pure functions: the database returns plan and actual on three
// levels (lib/data/plan.ts); this shapes them for the page and assigns the realization
// status. Kept separate so thresholds and edge cases are unit-tested.

export type PlanLevel = "store" | "region" | "network";

export type PlanRow = {
  level: PlanLevel;
  storeCode: string | null;
  storeName: string | null;
  regionCode: string | null;
  regionName: string | null;
  /** First day of the month (YYYY-MM-DD); null = total for the period. */
  month: string | null;
  plan: number;
  actual: number;
  /** actual / plan; null when the plan is 0. */
  realization: number | null;
  deviation: number;
};

export type PlanFigures = Pick<PlanRow, "plan" | "actual" | "realization" | "deviation">;

/** Realization thresholds from the requirements: < 90% red, 90-100% yellow, >= 100% green. */
export const THRESHOLDS = { low: 0.9, met: 1 } as const;

export type PlanStatus = "below" | "near" | "met";

export function planStatus(realization: number | null): PlanStatus | null {
  if (realization === null) return null;
  if (realization < THRESHOLDS.low) return "below";
  if (realization < THRESHOLDS.met) return "near";
  return "met";
}

// ---------------------------------------------------------------- full months

function iso(y: number, m: number, d: number): string {
  return new Date(Date.UTC(y, m, d)).toISOString().slice(0, 10);
}

/**
 * The full calendar months inside [from, to] (first days, YYYY-MM-DD), mirroring the
 * database: a partial month at either end is left out. `end` is the last day of the last
 * full month, so `first === from && end === to` means nothing was cut. Null when none.
 */
export function fullMonths(
  from: string,
  to: string,
): { first: string; last: string; end: string; count: number } | null {
  const [fy, fm, fd] = from.split("-").map(Number);
  const [ty, tm, td] = to.split("-").map(Number);
  const first = fd === 1 ? iso(fy, fm - 1, 1) : iso(fy, fm, 1);
  // Last full month: the month of `to` if `to` is its last day, otherwise the one before.
  const lastDayOfMonth = new Date(Date.UTC(ty, tm, 0)).getUTCDate();
  const last = td === lastDayOfMonth ? iso(ty, tm - 1, 1) : iso(ty, tm - 2, 1);
  if (first > last) return null;
  const [ly, lm] = last.split("-").map(Number);
  const [y0, m0] = first.split("-").map(Number);
  return { first, last, end: iso(ly, lm, 0), count: (ly - y0) * 12 + (lm - m0) + 1 };
}

const monthFormatter = new Intl.DateTimeFormat("pl-PL", { month: "short", year: "numeric", timeZone: "UTC" });
const monthLongFormatter = new Intl.DateTimeFormat("pl-PL", { month: "long", year: "numeric", timeZone: "UTC" });

/** "2025-10-01" -> "paź 2025" (column headers). */
export function formatMonth(month: string): string {
  return monthFormatter.format(new Date(`${month}T00:00:00Z`));
}

/** "2025-10-01" -> "październik 2025" (tooltips, text). */
export function formatMonthLong(month: string): string {
  return monthLongFormatter.format(new Date(`${month}T00:00:00Z`));
}

// ---------------------------------------------------------------- shaping

export type RegionSummary = PlanFigures & {
  key: string;
  regionCode: string | null;
  regionName: string;
  stores: number;
};

export type StoreSummary = PlanFigures & {
  storeCode: string;
  storeName: string;
  regionCode: string | null;
  regionName: string;
  /** Monthly figures by month (YYYY-MM-01); a missing month had neither plan nor sales. */
  months: Record<string, PlanFigures>;
};

export type PlanView = {
  months: string[];
  network: PlanFigures | null;
  networkMonths: Record<string, PlanFigures>;
  regions: RegionSummary[];
  stores: StoreSummary[];
};

const figures = (r: PlanRow): PlanFigures => ({
  plan: r.plan,
  actual: r.actual,
  realization: r.realization,
  deviation: r.deviation,
});

const regionKey = (r: Pick<PlanRow, "regionCode">) => r.regionCode ?? "online";

export function buildPlanView(rows: PlanRow[]): PlanView {
  const months = new Set<string>();
  const networkMonths: Record<string, PlanFigures> = {};
  let network: PlanFigures | null = null;
  const regions = new Map<string, RegionSummary>();
  const stores = new Map<string, StoreSummary>();

  for (const r of rows) {
    if (r.month) months.add(r.month);
    if (r.level === "network") {
      if (r.month) networkMonths[r.month] = figures(r);
      else network = figures(r);
    } else if (r.level === "region" && !r.month) {
      regions.set(regionKey(r), {
        ...figures(r),
        key: regionKey(r),
        regionCode: r.regionCode,
        regionName: r.regionName ?? "",
        stores: 0,
      });
    } else if (r.level === "store" && r.storeCode) {
      let s = stores.get(r.storeCode);
      if (!s) {
        s = {
          plan: 0,
          actual: 0,
          realization: null,
          deviation: 0,
          storeCode: r.storeCode,
          storeName: r.storeName ?? r.storeCode,
          regionCode: r.regionCode,
          regionName: r.regionName ?? "",
          months: {},
        };
        stores.set(r.storeCode, s);
      }
      if (r.month) s.months[r.month] = figures(r);
      else Object.assign(s, figures(r));
    }
  }

  for (const s of stores.values()) {
    const region = regions.get(regionKey(s));
    if (region) region.stores += 1;
  }

  const collator = new Intl.Collator("pl");
  return {
    months: [...months].sort(),
    network,
    networkMonths,
    regions: [...regions.values()].sort((a, b) => collator.compare(a.regionName, b.regionName)),
    stores: [...stores.values()].sort((a, b) => collator.compare(a.storeCode, b.storeCode)),
  };
}
