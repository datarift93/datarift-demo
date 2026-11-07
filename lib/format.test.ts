import { describe, expect, it } from "vitest";

import { formatDate, formatInteger, formatPercent, formatPLN } from "./format";

// Intl uses non-breaking spaces; normalize them so expectations stay readable.
const plain = (s: string) => s.replace(/ /g, " ");

describe("formatPLN", () => {
  it("formats with spaces, decimal comma and zł", () => {
    expect(plain(formatPLN(1234567.89))).toBe("1 234 567,89 zł");
  });

  it("groups 4-digit amounts and keeps two decimals", () => {
    expect(plain(formatPLN(1234.5))).toBe("1 234,50 zł");
  });

  it("formats negatives and zero", () => {
    expect(plain(formatPLN(-42))).toBe("-42,00 zł");
    expect(plain(formatPLN(0))).toBe("0,00 zł");
  });

  it("uses non-breaking spaces so amounts do not wrap", () => {
    expect(formatPLN(1000)).not.toMatch(/ /);
  });
});

describe("formatInteger", () => {
  it("rounds and groups", () => {
    expect(plain(formatInteger(1234567.6))).toBe("1 234 568");
  });
});

describe("formatPercent", () => {
  it("converts a ratio with a decimal comma", () => {
    expect(formatPercent(0.1234)).toBe("12,3%");
  });

  it("respects digits", () => {
    expect(formatPercent(0.5, { digits: 0 })).toBe("50%");
  });

  it("adds a sign for changes when signed", () => {
    expect(formatPercent(0.034, { signed: true })).toBe("+3,4%");
    expect(formatPercent(-0.05, { signed: true })).toBe("-5,0%");
    expect(formatPercent(0, { signed: true })).toBe("0,0%");
  });
});

describe("formatDate", () => {
  it("reformats ISO dates without time zone shifts", () => {
    expect(formatDate("2026-11-02")).toBe("02.11.2026");
    expect(formatDate("2025-01-01")).toBe("01.01.2025");
  });

  it("formats Date objects in Warsaw time", () => {
    // 23:30 UTC on 31.12 is already 01.01 in Warsaw (UTC+1).
    expect(formatDate(new Date("2025-12-31T23:30:00Z"))).toBe("01.01.2026");
  });

  it("throws on invalid input", () => {
    expect(() => formatDate("not a date")).toThrow(RangeError);
  });
});
