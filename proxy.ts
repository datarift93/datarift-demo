import { NextResponse, type NextRequest } from "next/server";

import { APP_ROUTES } from "@/lib/navigation";
import { updateSession } from "@/lib/supabase/proxy";

export async function proxy(request: NextRequest) {
  const { response, signedIn } = await updateSession(request);

  // Optimistic check only; every page also verifies the user through lib/auth.ts.
  const { pathname } = request.nextUrl;
  const isAppRoute = APP_ROUTES.some((r) => pathname === r || pathname.startsWith(`${r}/`));
  if (isAppRoute && !signedIn) {
    const url = request.nextUrl.clone();
    url.pathname = "/";
    url.search = "";
    return NextResponse.redirect(url);
  }
  return response;
}

export const config = {
  // Everything except static files and images.
  matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)"],
};
