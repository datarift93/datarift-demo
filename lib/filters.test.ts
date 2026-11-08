import { describe, expect, it } from "vitest";

import {
  addDays,
  defaultPeriod,
  filtersHref,
  isDefault,
  isValidIsoDate,
  parseFilters,
  periodDays,
  presets,
  previousPeriod,
  toSearchParams,
  type DataRange,
  type Filters,
} from "./filters";

const RANGE: DataRange = { min: "2024-01-01", max: "2025-12-31" };
const OPTIONS = { regions: ["02", "14"], categories: ["HOME", "SPORT"] };
const DEFAULT: Filters = { from: "2025-10-01", to: "2025-12-31", channel: null, region: null, category: null };

describe("dates", () => {
  it("validates real calendar dates only", () => {
    expect(isValidIsoDate("2024-02-29")).toBe(true);
    expect(isValidIsoDate("2025-02-29")).toBe(false);
    expect(isValidIsoDate("2025-13-01")).toBe(false);
    expect(isValidIsoDate("01.10.2025")).toBe(false);
  });

  it("adds days across months and years", () => {
    expect(addDays("2025-12-31", 1)).toBe("2026-01-01");
    expect(addDays("2024-03-01", -1)).toBe("2024-02-29");
  });

  it("counts both ends of a period", () => {
    expect(periodDays("2025-10-01", "2025-12-31")).toBe(92);
    expect(periodDays("2025-01-01", "2025-01-01")).toBe(1);
  });
});

describe("defaults and presets", () => {
  it("defaults to the last three calendar months of data", () => {
    expect(defaultPeriod(RANGE)).toEqual({ from: "2025-10-01", to: "2025-12-31" });
  });

  it("offers presets ending on the last day of data, clamped to the data range", () => {
    const byId = Object.fromEntries(presets(RANGE).map((p) => [p.id, p]));
    expect(byId["30-dni"]).toMatchObject({ from: "2025-12-02", to: "2025-12-31" });
    expect(byId["12-miesiecy"]).toMatchObject({ from: "2025-01-01", to: "2025-12-31" });
    expect(byId["rok-2024"]).toMatchObject({ from: "2024-01-01", to: "2024-12-31" });
    expect(byId["calosc"]).toMatchObject({ from: "2024-01-01", to: "2025-12-31" });
  });

  it("gives the previous period of the same length", () => {
    // 92 days (Oct-Dec) before 1 October: Jul + Aug + Sep is also exactly 92 days.
    expect(previousPeriod("2025-10-01", "2025-12-31")).toEqual({ from: "2025-07-01", to: "2025-09-30" });
    expect(previousPeriod("2025-03-01", "2025-03-31")).toEqual({ from: "2025-01-29", to: "2025-02-28" });
  });
});

describe("parseFilters", () => {
  it("uses the defaults for an empty URL", () => {
    expect(parseFilters(new URLSearchParams(), RANGE, OPTIONS)).toEqual(DEFAULT);
  });

  it("reads every filter from Polish parameters", () => {
    const params = new URLSearchParams("od=2025-01-01&do=2025-03-31&kanal=online&region=14&kategoria=HOME");
    expect(parseFilters(params, RANGE, OPTIONS)).toEqual({
      from: "2025-01-01",
      to: "2025-03-31",
      channel: "online",
      region: "14",
      category: "HOME",
    });
  });

  it("accepts Next.js searchParams objects (first value of arrays)", () => {
    expect(parseFilters({ kanal: ["sklepy", "online"], region: undefined }, RANGE).channel).toBe("store");
  });

  it("falls back to defaults for invalid or reversed dates", () => {
    expect(parseFilters(new URLSearchParams("od=2025-02-30"), RANGE)).toMatchObject({ from: "2025-10-01" });
    expect(parseFilters(new URLSearchParams("od=2025-06-01&do=2025-01-01"), RANGE)).toMatchObject({
      from: "2025-10-01",
      to: "2025-12-31",
    });
  });

  it("clamps dates to the data range", () => {
    expect(parseFilters(new URLSearchParams("od=2020-01-01&do=2030-01-01"), RANGE)).toMatchObject({
      from: "2024-01-01",
      to: "2025-12-31",
    });
  });

  it("ignores unknown channels, regions and categories", () => {
    const params = new URLSearchParams("kanal=hurt&region=99&kategoria=XYZ");
    expect(parseFilters(params, RANGE, OPTIONS)).toEqual(DEFAULT);
  });
});

describe("toSearchParams / filtersHref", () => {
  it("leaves out defaults, so the default view has a clean URL", () => {
    expect(toSearchParams(DEFAULT, RANGE).toString()).toBe("");
    expect(filtersHref("/kpi", DEFAULT, RANGE)).toBe("/kpi");
    expect(isDefault(DEFAULT, RANGE)).toBe(true);
  });

  it("round-trips every filter through the URL", () => {
    const filters: Filters = { from: "2024-11-01", to: "2024-11-30", channel: "store", region: "02", category: "SPORT" };
    const href = filtersHref("/produkty", filters, RANGE);
    expect(href).toBe("/produkty?od=2024-11-01&do=2024-11-30&kanal=sklepy&region=02&kategoria=SPORT");
    const parsed = parseFilters(new URLSearchParams(href.split("?")[1]), RANGE, OPTIONS);
    expect(parsed).toEqual(filters);
    expect(isDefault(parsed, RANGE)).toBe(false);
  });
});
