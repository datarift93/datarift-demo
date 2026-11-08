import type { Metadata } from "next";

import { ViewPlaceholder } from "@/components/data/view-placeholder";

export const metadata: Metadata = { title: "Anomalie | Wisła · demo BI" };

export default function AnomaliesPage() {
  return (
    <ViewPlaceholder
      title="Anomalie"
      description="Automatyczne alerty o odchyleniach"
      stage="Etap 7"
      features={[
        "Spadki sprzedaży sklepów bez fałszywych alarmów w Black Friday i grudniu",
        "Spadki marży kategorii i nietypowe wahania zamówień online",
        "Opis każdego alertu po polsku z linkiem do widoku z ustawionymi filtrami",
      ]}
    />
  );
}
