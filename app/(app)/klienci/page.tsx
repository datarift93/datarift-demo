import type { Metadata } from "next";

import { ViewPlaceholder } from "@/components/data/view-placeholder";

export const metadata: Metadata = { title: "Klienci | Wisła · demo BI" };

export default function CustomersPage() {
  return (
    <ViewPlaceholder
      title="Klienci"
      description="Segmentacja RFM i kohorty retencji"
      stage="Etap 6"
      features={[
        "Segmenty RFM: Lojalni, Zagrożeni odejściem, Utraceni, Nowi",
        "Macierz kohort miesięcznych jako mapa ciepła",
      ]}
    />
  );
}
