import type { Metadata } from "next";
import Link from "next/link";

import { LoginForm } from "./login-form";

export const metadata: Metadata = { title: "Logowanie | datarift demo" };

export default function LoginPage() {
  return (
    <main className="mx-auto flex w-full max-w-sm flex-1 flex-col justify-center gap-6 px-4 py-16">
      <div className="flex flex-col gap-2">
        <h1 className="text-2xl font-semibold tracking-tight">Logowanie administratora</h1>
        <p className="text-sm text-muted-foreground">
          Konta zakłada administrator. Chcesz tylko obejrzeć dane?{" "}
          <Link href="/" className="underline underline-offset-4">
            Zobacz demo
          </Link>
          .
        </p>
      </div>
      <LoginForm />
    </main>
  );
}
