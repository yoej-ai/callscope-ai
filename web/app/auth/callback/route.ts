import { NextResponse, type NextRequest } from "next/server";

import { resolveSafeAuthRedirect } from "@/lib/auth/redirect-target.mjs";
import { createClient } from "@/lib/supabase/server";

export async function GET(request: NextRequest) {
  const requestUrl = new URL(request.url);
  const code = requestUrl.searchParams.get("code");
  const redirectUrl = resolveSafeAuthRedirect(
    requestUrl,
    requestUrl.searchParams.get("next"),
  );

  if (!code) {
    return NextResponse.redirect(
      new URL("/sign-in?message=Missing%20authentication%20code.", request.url),
    );
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.exchangeCodeForSession(code);

  if (error) {
    return NextResponse.redirect(
      new URL("/sign-in?message=Authentication%20could%20not%20be%20completed.", request.url),
    );
  }

  return NextResponse.redirect(redirectUrl);
}
