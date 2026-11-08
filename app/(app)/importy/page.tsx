import type { Metadata } from "next";
import { Suspense } from "react";

import { PageHeader, TableSkeleton } from "@/components/data/states";
import { listImportRuns } from "@/lib/data/imports";

import { ImportRunsTable } from "./import-tables";

export const metadata: Metadata = { title: "Importy | Wisła · demo BI" };

async function Runs() {
  const runs = await listImportRuns();
  return <ImportRunsTable runs={runs} />;
}

export default function ImportsPage() {
  return (
    <>
      <PageHeader
        title="Importy"
        description="Każde uruchomienie pipeline'u: staging, walidacja, model i log. Kliknij datę, aby zobaczyć błędy."
      />
      <Suspense fallback={<TableSkeleton rows={3} />}>
        <Runs />
      </Suspense>
    </>
  );
}
