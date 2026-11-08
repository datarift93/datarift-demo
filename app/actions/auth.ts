"use server";

import { redirect } from "next/navigation";

import { HOME_ROUTE } from "@/lib/navigation";
import { createClient } from "@/lib/supabase/server";

/**
 * One-click demo login. The demo credentials live only in server env vars and never
 * reach the browser. The account is read-only, enforced by RLS in the database.
 */
export async function signInAsDemo() {
  const email = process.env.DEMO_USER_EMAIL;
  const password = process.env.DEMO_USER_PASSWORD;
  if (!email || !password) {
    console.error("[demo login] DEMO_USER_EMAIL or DEMO_USER_PASSWORD is not set");
    redirect("/?blad=demo-niedostepne");
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) {
    // Visible in Vercel logs: wrong password, missing user or the auth rate limit (429).
    console.error(`[demo login] ${error.status ?? ""} ${error.code ?? ""}: ${error.message}`);
    redirect("/?blad=demo-niedostepne");
  }
  redirect(HOME_ROUTE);
}

export type SignInState = { error: string | null };

export async function signIn(_prev: SignInState, formData: FormData): Promise<SignInState> {
  const email = String(formData.get("email") ?? "").trim();
  const password = String(formData.get("password") ?? "");
  if (!email || !password) return { error: "Podaj e-mail i hasło." };

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) {
    // Same message for unknown e-mail and wrong password (no account enumeration).
    return { error: "Nieprawidłowy e-mail lub hasło." };
  }
  redirect(HOME_ROUTE);
}

export async function signOut() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/");
}
