import Link from "next/link";
import { Suspense } from "react";

import { signInAsDemo } from "@/app/actions/auth";
import { LandingNotice } from "@/components/auth/landing-notice";
import { SubmitButton } from "@/components/auth/submit-button";
import { NAV_ITEMS } from "@/lib/navigation";

export default function Home() {
  return (
    <main className="mx-auto flex w-full max-w-4xl flex-1 flex-col gap-12 px-4 py-16 sm:px-8 sm:py-24">
      <section className="flex flex-col gap-6">
        <p className="text-sm font-medium text-muted-foreground">datarift · demo BI</p>
        <h1 className="text-3xl font-semibold tracking-tight sm:text-5xl">
          Analityka sprzedaży sieci „Wisła”
        </h1>
        <p className="max-w-2xl text-lg text-muted-foreground">
          25 sklepów stacjonarnych i sklep internetowy, dwa lata danych. Zobacz, jak wygląda
          kompletne rozwiązanie BI: od importu i walidacji danych po dashboardy i automatyczne
          wnioski.
        </p>
        <Suspense>
          <LandingNotice />
        </Suspense>
        <div className="flex flex-wrap items-center gap-4">
          <form action={signInAsDemo}>
            <SubmitButton size="lg" pendingLabel="Otwieram demo…">
              Zobacz demo
            </SubmitButton>
          </form>
          <p className="text-sm text-muted-foreground">
            Bez rejestracji, tylko do odczytu.{" "}
            <Link href="/logowanie" className="underline underline-offset-4">
              Logowanie administratora
            </Link>
          </p>
        </div>
      </section>

      <section className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {NAV_ITEMS.map((item) => (
          <div key={item.href} className="rounded-lg border p-4">
            <h2 className="font-medium">{item.label}</h2>
            <p className="mt-1 text-sm text-muted-foreground">{item.description}</p>
          </div>
        ))}
      </section>
    </main>
  );
}
