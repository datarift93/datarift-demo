import { describe, expect, it } from "vitest";

import { classBoundaries, paretoPoints, productsLabel, topShare, type AbcClass, type ProductRow } from "./products";

function row(rank: number, revenue: number, cumShare: number, abcClass: AbcClass): ProductRow {
  return {
    rank,
    sku: `P${rank}`,
    name: `Produkt ${rank}`,
    categoryCode: "X",
    categoryName: "Kategoria X",
    currency: "PLN",
    revenue,
    margin: revenue / 4,
    marginPct: revenue === 0 ? null : 0.25,
    units: 1,
    orders: 1,
    revenueShare: revenue / 1000,
    cumShare,
    abcClass,
  };
}

// The pgTAP fixture: 500, 300, 100, 50, 25, 25 (total 1000).
const rows = [
  row(1, 500, 0.5, "A"),
  row(2, 300, 0.8, "A"),
  row(3, 100, 0.9, "B"),
  row(4, 50, 0.95, "B"),
  row(5, 25, 0.975, "C"),
  row(6, 25, 1, "C"),
];

describe("paretoPoints", () => {
  it("starts at the origin and follows the ranking", () => {
    const points = paretoPoints([...rows].reverse());
    expect(points[0]).toMatchObject({ x: 0, y: 0, sku: null });
    expect(points.map((p) => p.sku).slice(1)).toEqual(["P1", "P2", "P3", "P4", "P5", "P6"]);
    expect(points[2]).toMatchObject({ x: 2 / 6, y: 0.8, abcClass: "A" });
    expect(points.at(-1)).toMatchObject({ x: 1, y: 1 });
  });

  it("is empty without products", () => {
    expect(paretoPoints([])).toEqual([]);
  });
});

describe("topShare", () => {
  it("takes the top 20% of products, rounded, at least one", () => {
    expect(topShare(rows)).toEqual({ products: 1, share: 0.5 });
    expect(topShare(rows, 0.5)).toEqual({ products: 3, share: 0.9 });
    expect(topShare(rows.slice(0, 1))).toEqual({ products: 1, share: 0.5 });
  });

  it("is null without products", () => {
    expect(topShare([])).toBeNull();
  });
});

describe("classBoundaries", () => {
  it("marks where A and B end on the product axis", () => {
    expect(classBoundaries(rows)).toEqual([
      { abcClass: "A", x: 2 / 6 },
      { abcClass: "B", x: 4 / 6 },
    ]);
  });

  it("skips boundaries at the edges or on top of each other", () => {
    expect(classBoundaries([row(1, 10, 1, "A")])).toEqual([]);
    expect(classBoundaries([row(1, 10, 0.9, "A"), row(2, 1, 1, "C")])).toEqual([{ abcClass: "A", x: 0.5 }]);
  });
});

describe("productsLabel", () => {
  it.each([
    [1, "produkt"],
    [2, "produkty"],
    [4, "produkty"],
    [5, "produktów"],
    [12, "produktów"],
    [22, "produkty"],
    [90, "produktów"],
    [0, "produktów"],
  ])("%i %s", (n, label) => {
    expect(productsLabel(n)).toBe(label);
  });
});
