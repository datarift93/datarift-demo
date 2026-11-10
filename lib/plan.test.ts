import { describe, expect, it } from "vitest";

import { buildPlanView, formatMonth, fullMonths, planStatus, type PlanRow } from "./plan";

describe("planStatus", () => {
  it("applies the thresholds < 90%, 90-100%, >= 100%", () => {
    expect(planStatus(0.5)).toBe("below");
    expect(planStatus(0.8999)).toBe("below");
    expect(planStatus(0.9)).toBe("near");
    expect(planStatus(0.9999)).toBe("near");
    expect(planStatus(1)).toBe("met");
    expect(planStatus(1.3)).toBe("met");
  });

  it("has no status without a plan", () => {
    expect(planStatus(null)).toBeNull();
  });
});

describe("fullMonths", () => {
  it("keeps whole months", () => {
    expect(fullMonths("2025-10-01", "2025-12-31")).toEqual({ first: "2025-10-01", last: "2025-12-01", end: "2025-12-31", count: 3 });
  });

  it("drops partial months at both ends", () => {
    expect(fullMonths("2025-10-15", "2025-12-30")).toEqual({ first: "2025-11-01", last: "2025-11-01", end: "2025-11-30", count: 1 });
  });

  it("handles February in leap and common years", () => {
    expect(fullMonths("2024-02-01", "2024-02-29")?.end).toBe("2024-02-29");
    expect(fullMonths("2024-02-01", "2024-02-28")).toBeNull();
    expect(fullMonths("2025-02-01", "2025-02-28")?.count).toBe(1);
  });

  it("crosses a year boundary", () => {
    expect(fullMonths("2024-12-02", "2026-01-31")).toEqual({ first: "2025-01-01", last: "2026-01-01", end: "2026-01-31", count: 13 });
    expect(fullMonths("2024-01-01", "2025-01-30")).toEqual({ first: "2024-01-01", last: "2024-12-01", end: "2024-12-31", count: 12 });
  });

  it("returns null when no month is complete", () => {
    expect(fullMonths("2025-12-02", "2025-12-31")).toBeNull();
    expect(fullMonths("2025-11-15", "2025-12-14")).toBeNull();
  });
});

describe("formatMonth", () => {
  it("uses Polish short month names", () => {
    expect(formatMonth("2025-10-01")).toBe("paź 2025");
  });
});

const row = (r: Partial<PlanRow> & Pick<PlanRow, "level">): PlanRow => ({
  storeCode: null,
  storeName: null,
  regionCode: null,
  regionName: null,
  month: null,
  plan: 100,
  actual: 90,
  realization: 0.9,
  deviation: -10,
  ...r,
});

describe("buildPlanView", () => {
  const rows: PlanRow[] = [
    row({ level: "network", plan: 300, actual: 250, realization: 250 / 300, deviation: -50 }),
    row({ level: "network", month: "2025-11-01" }),
    row({ level: "network", month: "2025-10-01" }),
    row({ level: "region", regionCode: "14", regionName: "mazowieckie" }),
    row({ level: "region", regionCode: null, regionName: "Sklep internetowy" }),
    row({ level: "region", regionCode: "12", regionName: "małopolskie" }),
    row({ level: "region", regionCode: "14", regionName: "mazowieckie", month: "2025-10-01" }),
    row({ level: "store", storeCode: "WAW-02", storeName: "Warszawa 2", regionCode: "14", regionName: "mazowieckie", plan: 50 }),
    row({ level: "store", storeCode: "WAW-01", storeName: "Warszawa 1", regionCode: "14", regionName: "mazowieckie" }),
    row({ level: "store", storeCode: "WAW-01", storeName: "Warszawa 1", regionCode: "14", regionName: "mazowieckie", month: "2025-10-01", plan: 40 }),
    row({ level: "store", storeCode: "ONLINE", storeName: "Sklep internetowy", regionName: "Sklep internetowy" }),
  ];
  const view = buildPlanView(rows);

  it("collects sorted months and the network totals", () => {
    expect(view.months).toEqual(["2025-10-01", "2025-11-01"]);
    expect(view.network).toEqual({ plan: 300, actual: 250, realization: 250 / 300, deviation: -50 });
    expect(Object.keys(view.networkMonths).sort()).toEqual(["2025-10-01", "2025-11-01"]);
  });

  it("lists regions in Polish order with their store counts, online as its own group", () => {
    expect(view.regions.map((r) => [r.regionName, r.stores])).toEqual([
      ["małopolskie", 0],
      ["mazowieckie", 2],
      ["Sklep internetowy", 1],
    ]);
  });

  it("puts period totals on the store and months in a lookup", () => {
    const waw = view.stores.find((s) => s.storeCode === "WAW-01");
    expect(view.stores.map((s) => s.storeCode)).toEqual(["ONLINE", "WAW-01", "WAW-02"]);
    expect(waw?.plan).toBe(100);
    expect(waw?.months["2025-10-01"]?.plan).toBe(40);
    expect(waw?.months["2025-11-01"]).toBeUndefined();
  });

  it("is empty without rows", () => {
    expect(buildPlanView([])).toEqual({ months: [], network: null, networkMonths: {}, regions: [], stores: [] });
  });
});
