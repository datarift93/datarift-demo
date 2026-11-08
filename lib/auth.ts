import "server-only";

import { redirect } from "next/navigation";
import { cache } from "react";

import { createClient } from "@/lib/supabase/server";

export type Role = "admin" | "demo";

export type CurrentUser = {
  id: string;
  orgId: string;
  email: string;
  role: Role;
  orgName: string;
};

/**
 * The signed-in user with their org and role (Data Access Layer). Redirects to the
 * landing page when nobody is signed in or the account has no organization.
 * Reads cookies: call it inside a <Suspense> boundary. Deduplicated per request
 * (the menu, the mobile menu and the demo banner all need it).
 *
 * A user may belong to several orgs (RLS lets them read all of them), so every data
 * query must also filter by `orgId`; the first membership by creation date is active.
 */
export const getCurrentUser = cache(async function getCurrentUser(): Promise<CurrentUser> {
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  const claims = data?.claims;
  if (!claims?.sub) redirect("/");

  // RLS returns only the user's own membership rows.
  const { data: member } = await supabase
    .from("org_members")
    .select("org_id, role, orgs(name)")
    .eq("user_id", claims.sub)
    .order("created_at")
    .limit(1)
    .maybeSingle();
  if (!member) redirect("/?blad=brak-organizacji");

  return {
    id: claims.sub,
    orgId: member.org_id,
    email: typeof claims.email === "string" ? claims.email : "",
    role: member.role as Role,
    orgName: (member.orgs as unknown as { name: string } | null)?.name ?? "",
  };
});
