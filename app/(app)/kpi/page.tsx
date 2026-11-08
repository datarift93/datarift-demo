import type { Metadata } from "next";

import { ViewPlaceholder } from "@/components/data/view-placeholder";

export const metadata: Metadata = { title: "KPI | Wisła · demo BI" };

export default function KpiPage() {
  return (
    <ViewPlaceholder
      title="KPI"
      description="Przychód, marża, zamówienia i średni koszyk"
      stage="Etap 5"
      features={[
        "Przychód, marża (kwotowo i %), liczba zamówień, średni koszyk",
        "Zmiana vs poprzedni okres tej samej długości",
        "Wykres przychodu w czasie (dzień, tydzień lub miesiąc)",
      ]}
    />
  );
}
