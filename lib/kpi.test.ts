import { describe, expect, it } from "vitest";

import { bucketCoverage, bucketLabel, bucketTick, computeKpis, direction, type PeriodTotals } from "./kpi";

const current: PeriodTotals = {
  dateFrom: "2025-10-01",
  dateTo: "2025-12-31",
  revenue: 1200,
  margin: 360,
  orders: 40,
  units: 100,
};
const previous: PeriodTotals = {
  dateFrom: "2025-07-01",
  dateTo: "2025-09-30",
  revenue: 1000,
  margin: 250,
  orders: 50,
  units: 90,
};

const byKey = (r: ReturnType<typeof computeKpis>) => Object.fromEntries(r.kpis.map((k) => [k.key, k]));

describe("computeKpis", () => {
  it("computes the four KPIs and their changes", () => {
    const k = byKey(computeKpis(current, previous, "2024-01-01"));
    expect(k.revenue).toMatchObject({ value: 1200, previous: 1000, change: 200, changeRatio: 0.2 });
    expect(k.orders).toMatchObject({ value: 40, previous: 50, change: -10, changeRatio: -0.2 });
    expect(k.basket.value).toBe(30); // 1200 / 40
    expect(k.basket.previous).toBe(20); // 1000 / 50
    expect(k.basket.changeRatio).toBeCloseTo(0.5);
  });

  it("gives the margin share and its change in percentage points", () => {
    const m = byKey(computeKpis(current, previous, "2024-01-01")).margin;
    expect(m.value).toBe(360);
    expect(m.share).toBeCloseTo(0.3);
    expect(m.shareChange).toBeCloseTo(0.05); // 30% - 25%
    expect(m.changeRatio).toBeCloseTo(0.44);
  });

  it("does not compare with a previous period that starts before the data", () => {
    const r = computeKpis(current, previous, "2025-08-01");
    expect(r.comparable).toBe(false);
    for (const k of r.kpis) {
      expect(k.change).toBeNull();
      expect(k.changeRatio).toBeNull();
      expect(k.previous).toBeNull();
    }
    expect(byKey(r).margin.shareChange).toBeNull();
  });

  it("has no basket or margin share without orders, and flags an empty period", () => {
    const r = computeKpis({ ...current, revenue: 0, margin: 0, orders: 0, units: 0 }, previous, "2024-01-01");
    expect(r.empty).toBe(true);
    const k = byKey(r);
    expect(k.basket.value).toBeNull();
    expect(k.basket.change).toBeNull();
    expect(k.margin.share).toBeNull();
    expect(k.revenue.changeRatio).toBe(-1);
  });

  it("has an absolute but no relative change when the previous value was 0", () => {
    const k = byKey(computeKpis(current, { ...previous, revenue: 0, margin: 0, orders: 0 }, "2024-01-01"));
    expect(k.revenue.change).toBe(1200);
    expect(k.revenue.changeRatio).toBeNull();
    expect(k.basket.change).toBeNull(); // no previous basket
  });

  it("renames the basket KPI under a category filter (it is no longer the whole basket)", () => {
    expect(byKey(computeKpis(current, previous, "2024-01-01")).basket.label).toBe("Średni koszyk");
    expect(byKey(computeKpis(current, previous, "2024-01-01", { categoryFiltered: true })).basket.label).toBe(
      "Średnia wartość kategorii w zamówieniu",
    );
  });

  it("treats a missing first day (no data at all) as not comparable", () => {
    expect(computeKpis(current, previous, null).comparable).toBe(false);
  });
});

describe("direction", () => {
  it("prefers the relative change and treats tiny changes as flat", () => {
    expect(direction(0.1, 5)).toBe("up");
    expect(direction(-0.1, -5)).toBe("down");
    expect(direction(0.0001, 1)).toBe("flat");
  });

  it("falls back to the absolute change", () => {
    expect(direction(null, 3)).toBe("up");
    expect(direction(null, 0)).toBe("flat");
    expect(direction(null, null)).toBeNull();
  });
});

describe("bucket labels", () => {
  it("names buckets in Polish", () => {
    expect(bucketLabel("2025-03-10", "day")).toBe("10.03.2025");
    expect(bucketLabel("2025-01-06", "week")).toBe("tydzień od 06.01.2025");
    expect(bucketLabel("2025-01-01", "month")).toBe("styczeń 2025");
  });

  it("uses short axis ticks", () => {
    expect(bucketTick("2025-03-10", "day")).toBe("10.03");
    expect(bucketTick("2025-01-06", "week")).toBe("06.01");
    expect(bucketTick("2025-01-01", "month")).toBe("sty 2025");
  });
});

describe("bucketCoverage", () => {
  it("flags partial first and last weeks of a period", () => {
    // Q4 2025: 01.10 is a Wednesday, 31.12 a Wednesday.
    expect(bucketCoverage("2025-10-01", "week", "2025-12-31")).toEqual({ days: 5, full: 7 });
    expect(bucketCoverage("2025-10-06", "week", "2025-12-31")).toEqual({ days: 7, full: 7 });
    expect(bucketCoverage("2025-12-29", "week", "2025-12-31")).toEqual({ days: 3, full: 7 });
  });

  it("handles months, including February and a period ending mid-month", () => {
    expect(bucketCoverage("2024-02-01", "month", "2025-12-31")).toEqual({ days: 29, full: 29 });
    expect(bucketCoverage("2025-12-01", "month", "2025-12-15")).toEqual({ days: 15, full: 31 });
    expect(bucketCoverage("2025-01-15", "month", "2025-12-31")).toEqual({ days: 17, full: 31 });
  });

  it("treats days as always full", () => {
    expect(bucketCoverage("2025-03-10", "day", "2025-03-10")).toEqual({ days: 1, full: 1 });
  });
});
