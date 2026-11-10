import { describe, expect, it } from "vitest";

import {
  buildCohortMatrix,
  cohortLabel,
  cohortLabelLong,
  percentCell,
  RETENTION_BINS,
  retentionBin,
  SEGMENT_INFO,
  SEGMENT_NAMES,
  totalCustomers,
  type CohortCell,
  type SegmentRow,
} from "./customers";

const cell = (cohortMonth: string, monthsSince: number, cohortSize: number, active: number): CohortCell => ({
  cohortMonth,
  monthsSince,
  cohortSize,
  active,
  retention: active / cohortSize,
});

describe("buildCohortMatrix", () => {
  it("lays cells out by cohort and month, padding past the last full month with null", () => {
    const m = buildCohortMatrix([
      cell("2025-11-01", 0, 10, 10),
      cell("2025-10-01", 0, 4, 4),
      cell("2025-10-01", 1, 4, 1),
      cell("2025-10-01", 2, 4, 2),
      cell("2025-11-01", 1, 10, 3),
    ]);
    expect(m.months).toEqual([0, 1, 2]);
    expect(m.rows.map((r) => r.cohortMonth)).toEqual(["2025-10-01", "2025-11-01"]);
    expect(m.rows[0].size).toBe(4);
    expect(m.rows[1].cells.map((c) => c?.active ?? null)).toEqual([10, 3, null]);
  });

  it("averages by cohort size over the cohorts that reached each month", () => {
    const m = buildCohortMatrix([
      cell("2025-10-01", 0, 4, 4),
      cell("2025-10-01", 1, 4, 1),
      cell("2025-11-01", 0, 12, 12),
      cell("2025-11-01", 1, 12, 3),
      cell("2025-10-01", 2, 4, 2),
    ]);
    expect(m.average[0]).toBe(1);
    expect(m.average[1]).toBeCloseTo(4 / 16);
    expect(m.average[2]).toBeCloseTo(0.5); // only the October cohort reached month 2
  });

  it("handles no cohorts", () => {
    expect(buildCohortMatrix([])).toEqual({ months: [], rows: [], average: [] });
  });
});

describe("retentionBin", () => {
  it("maps retention to the binned sequential scale (lower bound inclusive)", () => {
    expect(retentionBin(0)).toBe(0);
    expect(retentionBin(0.049)).toBe(0);
    expect(retentionBin(0.05)).toBe(1);
    expect(retentionBin(0.2)).toBe(4);
    expect(retentionBin(0.35)).toBe(5);
    expect(retentionBin(1)).toBe(RETENTION_BINS.length - 1);
  });

  it("bins are contiguous and cover 0..infinity", () => {
    RETENTION_BINS.forEach((b, i) => {
      if (i > 0) expect(b.from).toBe(RETENTION_BINS[i - 1].to);
    });
    expect(RETENTION_BINS[0].from).toBe(0);
    expect(RETENTION_BINS.at(-1)?.to).toBe(Infinity);
  });
});

describe("labels", () => {
  it("formats cohort months in Polish", () => {
    expect(cohortLabel("2024-03-01")).toBe("mar 2024");
    expect(cohortLabelLong("2024-03-01")).toBe("marzec 2024");
    expect(cohortLabel("2025-12-01")).toBe("gru 2025");
  });

  it("prints whole percents in cells", () => {
    expect(percentCell(1)).toBe("100");
    expect(percentCell(0.234)).toBe("23");
    expect(percentCell(0)).toBe("0");
  });
});

describe("segments", () => {
  it("describes every segment in the database's order", () => {
    expect(Object.keys(SEGMENT_INFO)).toEqual([...SEGMENT_NAMES]);
  });

  it("totals customers", () => {
    const rows = SEGMENT_NAMES.map(
      (segment, i): SegmentRow => ({
        segment,
        customers: i + 1,
        revenue: 0,
        avgRecencyDays: null,
        avgFrequency: null,
        shareCustomers: 0,
        shareRevenue: 0,
      }),
    );
    expect(totalCustomers(rows)).toBe(21);
  });
});
