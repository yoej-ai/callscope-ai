import { NextResponse, type NextRequest } from "next/server";

import { getAppUrl } from "@/lib/app-url";
import { completeAuthCallback } from "@/lib/auth/callback-flow.mjs";
import { createClient } from "@/lib/supabase/server";

export async function GET(request: NextRequest) {
  const redirectUrl = await completeAuthCallback(
    request.url,
    getAppUrl(),
    async (code) => {
      const supabase = await createClient();
      const { error } = await supabase.auth.exchangeCodeForSession(code);
      return !error;
    },
  );
  return NextResponse.redirect(redirectUrl);
}
