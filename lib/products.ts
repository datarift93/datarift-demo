// Product view (F2) logic. The database ranks products and assigns ABC classes
// (migration *_products_analytics); this turns the rows into what the page shows: the
// class tiles, the Pareto curve and its labels. Pure functions, unit-tested.

export type AbcClass = "A" | "B" | "C";

export type ProductRow = {
  rank: number;
  sku: string;
  name: string;
  categoryCode: string;
  categoryName: string;
  currency: "PLN" | "EUR";
  revenue: number;
  margin: number;
  /** margin / revenue (0-1); null when revenue is 0. */
  marginPct: number | null;
  units: number;
  orders: number;
  revenueShare: number | null;
  /** Cumulative revenue share including this product (0-1). */
  cumShare: number | null;
  abcClass: AbcClass;
};

export type AbcSummaryRow = {
  abcClass: AbcClass;
  products: number;
  revenue: number;
  revenueShare: number | null;
  productShare: number | null;
};

/** Upper bounds of the cumulative revenue share before a product (same as in the SQL). */
export const ABC_THRESHOLDS = { A: 0.8, B: 0.95 } as const;

export const ABC_INFO: Record<AbcClass, { title: string; rule: string }> = {
  A: { title: "Klasa A", rule: "Produkty tworzące pierwsze 80% przychodu" },
  B: { title: "Klasa B", rule: "Kolejne 15% przychodu (od 80% do 95%)" },
  C: { title: "Klasa C", rule: "Ostatnie 5% przychodu" },
};

export const ABC_RULE_NOTE =
  "Produkty są sortowane malejąco po przychodzie. Klasę wyznacza skumulowany udział produktów przed danym produktem, więc produkt, który przekracza próg 80%, należy jeszcze do klasy A.";

export type ParetoPoint = {
  /** Share of products (0-1) up to and including this one; 0 for the origin. */
  x: number;
  /** Cumulative revenue share (0-1). */
  y: number;
  rank: number;
  sku: string | null;
  name: string | null;
  abcClass: AbcClass | null;
};

/**
 * Pareto curve points: x = share of products (in ranking order), y = cumulative revenue
 * share. Starts at the origin so the curve is anchored at (0, 0).
 */
export function paretoPoints(rows: ProductRow[]): ParetoPoint[] {
  const n = rows.length;
  if (n === 0) return [];
  const sorted = [...rows].sort((a, b) => a.rank - b.rank);
  return [
    { x: 0, y: 0, rank: 0, sku: null, name: null, abcClass: null },
    ...sorted.map((r, i) => ({
      x: (i + 1) / n,
      y: r.cumShare ?? 0,
      rank: r.rank,
      sku: r.sku,
      name: r.name,
      abcClass: r.abcClass,
    })),
  ];
}

/**
 * Revenue share of the top `fraction` of products (rounded to whole products, at least
 * one): the "20% of products = X% of revenue" headline. Null without products.
 */
export function topShare(rows: ProductRow[], fraction = 0.2): { products: number; share: number } | null {
  if (rows.length === 0) return null;
  const sorted = [...rows].sort((a, b) => a.rank - b.rank);
  const products = Math.max(1, Math.round(rows.length * fraction));
  return { products, share: sorted[products - 1].cumShare ?? 0 };
}

/** Share of products (x on the Pareto chart) where each class ends. */
export function classBoundaries(rows: ProductRow[]): { abcClass: AbcClass; x: number }[] {
  const n = rows.length;
  if (n === 0) return [];
  const counts: Record<AbcClass, number> = { A: 0, B: 0, C: 0 };
  for (const r of rows) counts[r.abcClass] += 1;
  return [
    { abcClass: "A", x: counts.A / n },
    { abcClass: "B", x: (counts.A + counts.B) / n },
  ].filter((b, i, all) => b.x > 0 && b.x < 1 && (i === 0 || b.x !== all[i - 1].x)) as {
    abcClass: AbcClass;
    x: number;
  }[];
}

/** Polish plural of "produkt": 1 produkt, 2-4 produkty, 5+ produktów (12-14 too). */
export function productsLabel(n: number): string {
  const mod10 = n % 10;
  const mod100 = n % 100;
  if (n === 1) return "produkt";
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return "produkty";
  return "produktów";
}
