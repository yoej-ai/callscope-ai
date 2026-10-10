import { createServerClient } from "@supabase/ssr";
import { type NextRequest, NextResponse } from "next/server";

import { normalizeSafeAuthRedirectPath } from "@/lib/auth/redirect-target.mjs";
import { getSupabaseEnv } from "@/lib/supabase/env";

export async function updateSession(request: NextRequest) {
  let response = NextResponse.next({ request });
  const { url, publishableKey } = getSupabaseEnv();
  const supabase = createServerClient(url, publishableKey, {
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll(cookiesToSet) {
        cookiesToSet.forEach(({ name, value }) =>
          request.cookies.set(name, value),
        );
        response = NextResponse.next({ request });
        cookiesToSet.forEach(({ name, value, options }) =>
          response.cookies.set(name, value, options),
        );
      },
    },
  });

  const { data } = await supabase.auth.getClaims();
  const isProtectedRoute = ["/dashboard", "/onboarding"].some(
    (path) =>
      request.nextUrl.pathname === path ||
      request.nextUrl.pathname.startsWith(`${path}/`),
  );

  if (isProtectedRoute && !data?.claims) {
    const signInUrl = new URL("/sign-in", request.url);
    signInUrl.searchParams.set("message", "Please sign in to continue.");
    signInUrl.searchParams.set(
      "next",
      normalizeSafeAuthRedirectPath(
        `${request.nextUrl.pathname}${request.nextUrl.search}`,
      ),
    );
    return NextResponse.redirect(signInUrl);
  }

  return response;
}
