"use client";

import { Button } from "@/components/ui/button";

/** Shown when a view fails to load (e.g. the database is unreachable). */
export default function ViewError({ reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <div role="alert" className="flex flex-col items-start gap-3 rounded-lg border p-6">
      <h2 className="font-medium">Nie udało się wczytać widoku</h2>
      <p className="text-sm text-muted-foreground">
        Spróbuj ponownie. Jeśli problem się powtarza, dane mogą być chwilowo niedostępne.
      </p>
      <Button variant="outline" size="sm" onClick={reset}>
        Spróbuj ponownie
      </Button>
    </div>
  );
}
