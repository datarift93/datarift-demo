// Views of the app (Polish URLs, shown in the address bar). The proxy protects every
// route listed here; keep this the single source for the menu and the protection.
export const NAV_ITEMS = [
  { href: "/kpi", label: "KPI", description: "Przychód, marża, zamówienia i średni koszyk" },
  { href: "/produkty", label: "Produkty", description: "Ranking, analiza ABC i marża" },
  { href: "/klienci", label: "Klienci", description: "Segmentacja RFM i kohorty retencji" },
  { href: "/plan", label: "Plan vs wykonanie", description: "Realizacja budżetu sklepów" },
  { href: "/anomalie", label: "Anomalie", description: "Automatyczne alerty o odchyleniach" },
  { href: "/importy", label: "Importy", description: "Historia importów i błędy walidacji" },
] as const;

export const APP_ROUTES: readonly string[] = NAV_ITEMS.map((i) => i.href);

export const HOME_ROUTE = "/kpi";
