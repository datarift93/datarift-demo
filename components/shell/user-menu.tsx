import { signOut } from "@/app/actions/auth";
import { SubmitButton } from "@/components/auth/submit-button";
import { Badge } from "@/components/ui/badge";
import { getCurrentUser } from "@/lib/auth";

/** Signed-in user, org and role, with sign-out. Reads the session: render in <Suspense>. */
export async function UserMenu() {
  const user = await getCurrentUser();
  return (
    <div className="flex flex-col gap-3 text-sm">
      <div className="flex flex-col gap-1">
        <span className="font-medium">{user.orgName}</span>
        <span className="truncate text-muted-foreground" title={user.email}>
          {user.email}
        </span>
        <span>
          <Badge variant={user.role === "demo" ? "secondary" : "default"}>
            {user.role === "demo" ? "Demo: tylko odczyt" : "Administrator"}
          </Badge>
        </span>
      </div>
      <form action={signOut}>
        <SubmitButton variant="outline" size="sm" pendingLabel="Wylogowywanie…">
          Wyloguj
        </SubmitButton>
      </form>
    </div>
  );
}

/** Banner reminding demo users that the data is read-only. Render in <Suspense>. */
export async function DemoBanner() {
  const user = await getCurrentUser();
  if (user.role !== "demo") return null;
  return (
    <p className="border-b bg-muted/60 px-4 py-2 text-xs text-muted-foreground sm:px-6">
      Tryb demo: dane fikcyjnej sieci „Wisła”, tylko do odczytu. Ograniczenie wymusza baza danych
      (RLS), a nie tylko interfejs.
    </p>
  );
}
