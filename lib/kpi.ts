// KPI arithmetic for the F1 dashboard. Pure functions: the database returns sums
// (lib/data/kpi.ts), this turns them into the four KPIs and their change vs the previous
// period. Kept separate so every edge case (zero orders, no previous data) is unit-tested.

export type PeriodTotals = {
  dateFrom: string; // YYYY-MM-DD
  dateTo: string;
  revenue: number;
  margin: number;
  orders: number;
  units: number;
};

export type KpiKey = "revenue" | "margin" | "orders" | "basket";

export type Kpi = {
  key: KpiKey;
  label: string;
  value: number | null;
  /** Margin only: margin as a share of revenue (0-1). */
  share: number | null;
  previous: number | null;
  /** value - previous; null when there is nothing to compare with. */
  change: number | null;
  /** Relative change (0.1 = +10%); null when previous is 0 or not comparable. */
  changeRatio: number | null;
  /** Margin only: change of the margin share in percentage points (0.012 = +1.2 p.p.). */
  shareChange: number | null;
};

export type KpiResult = {
  kpis: Kpi[];
  current: PeriodTotals;
  previous: PeriodTotals;
  /** False when the previous period starts before the first day of data. */
  comparable: boolean;
  empty: boolean;
};

const ratio = (a: number, b: number): number | null => (b === 0 ? null : a / b);

function kpi(
  key: KpiKey,
  label: string,
  value: number | null,
  previous: number | null,
  comparable: boolean,
): Kpi {
  const both = comparable && value !== null && previous !== null;
  return {
    key,
    label,
    value,
    share: null,
    previous: comparable ? previous : null,
    change: both ? value - previous : null,
    changeRatio: both && previous !== 0 ? (value - previous) / Math.abs(previous) : null,
    shareChange: null,
  };
}

/**
 * The four F1 KPIs with changes vs the previous period of the same length.
 * `firstDay` is the first day with data: a previous period that starts before it is
 * incomplete, so no change is shown rather than a misleading +100%.
 */
export function computeKpis(
  current: PeriodTotals,
  previous: PeriodTotals,
  firstDay: string | null,
  { categoryFiltered = false }: { categoryFiltered?: boolean } = {},
): KpiResult {
  const comparable = firstDay !== null && previous.dateFrom >= firstDay;

  const margin = kpi("margin", "Marża", current.margin, previous.margin, comparable);
  const share = ratio(current.margin, current.revenue);
  const previousShare = ratio(previous.margin, previous.revenue);
  margin.share = share;
  margin.shareChange = comparable && share !== null && previousShare !== null ? share - previousShare : null;

  return {
    kpis: [
      kpi("revenue", "Przychód", current.revenue, previous.revenue, comparable),
      margin,
      kpi("orders", "Zamówienia", current.orders, previous.orders, comparable),
      kpi(
        "basket",
        // With a category filter this is the category's share of an order, not the basket.
        categoryFiltered ? "Średnia wartość kategorii w zamówieniu" : "Średni koszyk",
        ratio(current.revenue, current.orders),
        ratio(previous.revenue, previous.orders),
        comparable,
      ),
    ],
    current,
    previous,
    comparable,
    empty: current.orders === 0,
  };
}

export type Direction = "up" | "down" | "flat";

/** Direction of a change; tiny changes (< 0.05%) count as flat. */
export function direction(changeRatio: number | null, change: number | null): Direction | null {
  if (changeRatio !== null) {
    if (Math.abs(changeRatio) < 0.0005) return "flat";
    return changeRatio > 0 ? "up" : "down";
  }
  if (change === null) return null;
  if (change === 0) return "flat";
  return change > 0 ? "up" : "down";
}

// ---------------------------------------------------------------- time series labels

export type Grain = "day" | "week" | "month";

const monthLong = new Intl.DateTimeFormat("pl-PL", { month: "long", year: "numeric", timeZone: "UTC" });
const monthShort = new Intl.DateTimeFormat("pl-PL", { month: "short", year: "numeric", timeZone: "UTC" });

function dmy(iso: string): string {
  const [y, m, d] = iso.split("-");
  return `${d}.${m}.${y}`;
}

/** Full bucket name for tooltips and the table: "10.03.2025", "tydzień od 06.01.2025", "styczeń 2025". */
export function bucketLabel(bucket: string, grain: Grain): string {
  if (grain === "day") return dmy(bucket);
  if (grain === "week") return `tydzień od ${dmy(bucket)}`;
  return monthLong.format(new Date(`${bucket}T00:00:00Z`));
}

/** Short axis tick: "10.03", "06.01", "sty 2025". */
export function bucketTick(bucket: string, grain: Grain): string {
  if (grain === "month") return monthShort.format(new Date(`${bucket}T00:00:00Z`)).replace(".", "");
  const [, m, d] = bucket.split("-");
  return `${d}.${m}`;
}

export const GRAIN_LABEL: Record<Grain, string> = {
  day: "dziennie",
  week: "tygodniowo",
  month: "miesięcznie",
};

const DAY_MS = 86_400_000;
const utc = (iso: string) => Date.parse(`${iso}T00:00:00Z`);

/**
 * How many days of a bucket fall inside the period, and how many a full bucket has.
 * The first and last week/month of a period are often partial; drawn like the others
 * they would read as a drop in sales.
 */
export function bucketCoverage(bucket: string, grain: Grain, periodTo: string): { days: number; full: number } {
  if (grain === "day") return { days: 1, full: 1 };
  const start = new Date(utc(bucket));
  let naturalStart: Date;
  let full: number;
  if (grain === "week") {
    const isoDow = (start.getUTCDay() + 6) % 7; // 0 = Monday
    naturalStart = new Date(utc(bucket) - isoDow * DAY_MS);
    full = 7;
  } else {
    naturalStart = new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth(), 1));
    full = new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth() + 1, 0)).getUTCDate();
  }
  const naturalEnd = naturalStart.getTime() + (full - 1) * DAY_MS;
  const end = Math.min(naturalEnd, utc(periodTo));
  return { days: Math.round((end - start.getTime()) / DAY_MS) + 1, full };
}
