import type { Metadata } from "next";

import { ViewPlaceholder } from "@/components/data/view-placeholder";

export const metadata: Metadata = { title: "Plan vs wykonanie | Wisła · demo BI" };

export default function PlanPage() {
  return (
    <ViewPlaceholder
      title="Plan vs wykonanie"
      description="Realizacja budżetu sklepów"
      stage="Etap 6"
      features={[
        "Tabela sklep × miesiąc z % realizacji i kolorami",
        "Podsumowanie dla sieci, regionu i sklepu",
      ]}
    />
  );
}
