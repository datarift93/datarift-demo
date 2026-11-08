"use client";

import { useSearchParams } from "next/navigation";

import { Alert, AlertDescription } from "@/components/ui/alert";

const MESSAGES: Record<string, string> = {
  "demo-niedostepne": "Demo jest chwilowo niedostępne. Spróbuj ponownie za chwilę.",
  "brak-organizacji": "To konto nie jest przypisane do żadnej organizacji.",
};

/** Shows the reason a user was sent back to the landing page (?blad=...). */
export function LandingNotice() {
  const code = useSearchParams().get("blad");
  const message = code ? MESSAGES[code] : undefined;
  if (!message) return null;
  return (
    <Alert variant="destructive" role="alert">
      <AlertDescription>{message}</AlertDescription>
    </Alert>
  );
}
