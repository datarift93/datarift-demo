import type { Metadata } from "next";

import { ViewPlaceholder } from "@/components/data/view-placeholder";

export const metadata: Metadata = { title: "Produkty | Wisła · demo BI" };

export default function ProductsPage() {
  return (
    <ViewPlaceholder
      title="Produkty"
      description="Ranking, analiza ABC i marża"
      stage="Etap 6"
      features={[
        "Ranking według przychodu, marży i liczby sztuk",
        "Analiza ABC z wykresem Pareto",
        "Marża z kosztem zakupu przeliczonym po kursie NBP",
      ]}
    />
  );
}
