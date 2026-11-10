// F3 Klienci: pure logic for the RFM segments and the retention cohort matrix. The database
// returns aggregates (lib/data/customers.ts, migration *_customers_analytics); this shapes
// them for the UI. Kept separate so the edge cases are unit-tested.

export const SEGMENT_NAMES = [
  "Mistrzowie",
  "Lojalni",
  "Nowi",
  "Obiecujący",
  "Zagrożeni odejściem",
  "Utraceni",
] as const;

export type SegmentName = (typeof SEGMENT_NAMES)[number];

export type SegmentRow = {
  segment: SegmentName;
  customers: number;
  revenue: number;
  avgRecencyDays: number | null;
  avgFrequency: number | null;
  shareCustomers: number;
  shareRevenue: number;
};

export type ScoreBand = {
  dimension: "R" | "F" | "M";
  score: number;
  customers: number;
  min: number;
  max: number;
};

export type CohortCell = {
  cohortMonth: string; // YYYY-MM-01
  monthsSince: number;
  cohortSize: number;
  active: number;
  retention: number; // 0-1
};

/** Rule (first match wins, as in the database) and a short plain-language description. */
export const SEGMENT_INFO: Record<SegmentName, { rule: string; description: string }> = {
  Mistrzowie: { rule: "R ≥ 4 i F ≥ 4", description: "Kupują często i niedawno. Najcenniejsza grupa." },
  Lojalni: { rule: "F ≥ 4", description: "Kupują często, ale ostatni zakup był dawniej." },
  Nowi: { rule: "R ≥ 4 i 1 zamówienie w 12 mies.", description: "Niedawny pierwszy (jedyny) zakup w ostatnim roku." },
  Obiecujący: { rule: "R ≥ 3", description: "Kupowali niedawno, jeszcze nie często." },
  "Zagrożeni odejściem": { rule: "R = 2", description: "Długo bez zakupu. Warto ich odzyskać." },
  Utraceni: { rule: "R = 1", description: "Najdłużej bez zakupu: 20% klientów z najstarszym ostatnim zakupem." },
};

export const DIMENSION_LABEL: Record<ScoreBand["dimension"], string> = {
  R: "R: dni od ostatniego zakupu",
  F: "F: zamówienia w 12 mies.",
  M: "M: przychód w 12 mies.",
};

export function totalCustomers(rows: SegmentRow[]): number {
  return rows.reduce((sum, r) => sum + r.customers, 0);
}

// ------------------------------------------------------------------ cohort matrix

export type CohortRow = {
  cohortMonth: string;
  size: number;
  /** Index = months since the first purchase; null past the last full month of data. */
  cells: (CohortCell | null)[];
};

export type CohortMatrix = {
  months: number[]; // 0..max months_since
  rows: CohortRow[];
  /** Size-weighted retention per month over the cohorts that reached it. */
  average: (number | null)[];
};

export function buildCohortMatrix(cells: CohortCell[]): CohortMatrix {
  const maxMonth = cells.reduce((m, c) => Math.max(m, c.monthsSince), -1);
  const months = Array.from({ length: maxMonth + 1 }, (_, i) => i);
  const byCohort = new Map<string, CohortRow>();
  for (const c of cells) {
    let row = byCohort.get(c.cohortMonth);
    if (!row) {
      row = { cohortMonth: c.cohortMonth, size: c.cohortSize, cells: months.map(() => null) };
      byCohort.set(c.cohortMonth, row);
    }
    row.cells[c.monthsSince] = c;
  }
  const rows = [...byCohort.values()].sort((a, b) => a.cohortMonth.localeCompare(b.cohortMonth));
  const average = months.map((k) => {
    let active = 0;
    let size = 0;
    for (const r of rows) {
      const cell = r.cells[k];
      if (cell) {
        active += cell.active;
        size += cell.cohortSize;
      }
    }
    return size === 0 ? null : active / size;
  });
  return { months, rows, average };
}

// ------------------------------------------------------------------ color scale

/**
 * Sequential single-hue scale (blue, dataviz reference ramp steps 100-700), binned so
 * the legend can name each band. Dark mode flips the anchor: low values stay close to
 * the dark surface. Every cell also prints its value, so the lightest band may recede.
 */
export const RETENTION_BINS = [
  { from: 0, to: 0.05, light: "#cde2fb", dark: "#0d366b", inkLight: "#1a1a19", inkDark: "#ffffff" },
  { from: 0.05, to: 0.1, light: "#9ec5f4", dark: "#184f95", inkLight: "#1a1a19", inkDark: "#ffffff" },
  { from: 0.1, to: 0.15, light: "#6da7ec", dark: "#256abf", inkLight: "#1a1a19", inkDark: "#ffffff" },
  { from: 0.15, to: 0.2, light: "#3987e5", dark: "#3987e5", inkLight: "#1a1a19", inkDark: "#1a1a19" },
  { from: 0.2, to: 0.3, light: "#256abf", dark: "#6da7ec", inkLight: "#ffffff", inkDark: "#1a1a19" },
  { from: 0.3, to: 0.5, light: "#184f95", dark: "#9ec5f4", inkLight: "#ffffff", inkDark: "#1a1a19" },
  { from: 0.5, to: Infinity, light: "#0d366b", dark: "#cde2fb", inkLight: "#ffffff", inkDark: "#1a1a19" },
] as const;

export function retentionBin(retention: number): number {
  const i = RETENTION_BINS.findIndex((b) => retention < b.to);
  return i === -1 ? RETENTION_BINS.length - 1 : Math.max(i, 0);
}

// ------------------------------------------------------------------ labels

const monthShort = new Intl.DateTimeFormat("pl-PL", { month: "short", year: "numeric", timeZone: "UTC" });
const monthLong = new Intl.DateTimeFormat("pl-PL", { month: "long", year: "numeric", timeZone: "UTC" });

/** "2024-03-01" -> "mar 2024" (short, for row headers). */
export function cohortLabel(month: string): string {
  return monthShort.format(new Date(`${month}T00:00:00Z`)).replace(".", "");
}

/** "2024-03-01" -> "marzec 2024". */
export function cohortLabelLong(month: string): string {
  return monthLong.format(new Date(`${month}T00:00:00Z`));
}

/** Retention as a whole percent for heatmap cells: 0.234 -> "23". */
export function percentCell(ratio: number): string {
  return String(Math.round(ratio * 100));
}
