import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

import { completeAuthCallback } from "../lib/auth/callback-flow.mjs";
import {
  createAuthCallbackUrl,
  createGoogleOAuthSignInOptions,
} from "../lib/auth/oauth-options.mjs";

const APP_URL = "https://app.example.com";
const GENERIC_ERROR = "Authentication could not be completed. Please try again.";

describe("Google OAuth options", () => {
  it("uses Google with the centralized callback and a safe destination", () => {
    const options = createGoogleOAuthSignInOptions(
      APP_URL,
      "/dashboard/calls/123?tab=analysis",
    );
    const callbackUrl = new URL(options.options.redirectTo);

    assert.equal(options.provider, "google");
    assert.equal(callbackUrl.origin, APP_URL);
    assert.equal(callbackUrl.pathname, "/auth/callback");
    assert.equal(
      callbackUrl.searchParams.get("next"),
      "/dashboard/calls/123?tab=analysis",
    );
  });

  it("falls back before placing an unsafe destination in the callback", () => {
    for (const target of [null, "", "https://evil.example", "//evil.example"]) {
      const callbackUrl = new URL(createAuthCallbackUrl(APP_URL, target));
      assert.equal(callbackUrl.searchParams.get("next"), "/dashboard");
    }
  });
});

describe("OAuth callback completion", () => {
  it("exchanges a valid code once and returns the safe requested path", async () => {
    const exchangedCodes = [];
    const destination = await completeAuthCallback(
      `${APP_URL}/auth/callback?code=valid-code&next=%2Fdashboard%2Fcalls%2F123%3Ftab%3Danalysis`,
      APP_URL,
      async (code) => {
        exchangedCodes.push(code);
        return true;
      },
    );

    assert.deepEqual(exchangedCodes, ["valid-code"]);
    assert.equal(
      destination.href,
      `${APP_URL}/dashboard/calls/123?tab=analysis`,
    );
  });

  it("uses one generic failure for missing, malformed, or failed codes", async () => {
    const requests = [
      `${APP_URL}/auth/callback`,
      `${APP_URL}/auth/callback?code=bad%0Acode`,
      `${APP_URL}/auth/callback?code=rejected-code`,
    ];

    for (const request of requests) {
      const destination = await completeAuthCallback(
        request,
        APP_URL,
        async () => false,
      );
      assert.equal(destination.pathname, "/sign-in");
      assert.equal(destination.searchParams.get("message"), GENERIC_ERROR);
      assert.equal(destination.searchParams.get("next"), "/dashboard");
    }
  });

  it("does not exchange or expose provider error parameters", async () => {
    let exchangeAttempted = false;
    const destination = await completeAuthCallback(
      `${APP_URL}/auth/callback?error=access_denied&error_description=private-provider-detail&next=%2Fonboarding`,
      APP_URL,
      async () => {
        exchangeAttempted = true;
        return true;
      },
    );

    assert.equal(exchangeAttempted, false);
    assert.equal(destination.pathname, "/sign-in");
    assert.equal(destination.searchParams.get("message"), GENERIC_ERROR);
    assert.equal(destination.searchParams.get("next"), "/onboarding");
    assert.equal(destination.href.includes("private-provider-detail"), false);
    assert.equal(destination.href.includes("access_denied"), false);
  });

  it("uses the configured application origin instead of an incoming host", async () => {
    const destination = await completeAuthCallback(
      "https://untrusted-host.example/auth/callback?code=valid-code&next=%2Fdashboard",
      APP_URL,
      async () => true,
    );

    assert.equal(destination.href, `${APP_URL}/dashboard`);
  });
});

describe("authentication regression contracts", () => {
  it("keeps email/password actions and fields alongside Google", async () => {
    const [actions, form] = await Promise.all([
      readFile(new URL("../app/auth/actions.ts", import.meta.url), "utf8"),
      readFile(new URL("../components/auth-form.tsx", import.meta.url), "utf8"),
    ]);

    assert.match(actions, /auth\.signInWithPassword\(/);
    assert.match(actions, /auth\.signUp\(/);
    assert.match(actions, /auth\.signInWithOAuth\(/);
    assert.match(actions, /auth\.signOut\(/);
    assert.doesNotMatch(actions, /linkIdentity|provider_token|provider_refresh_token/);
    assert.match(form, /Continue with Google/);
    assert.match(form, /name="email"/);
    assert.match(form, /name="password"/);
  });

  it("keeps the shared no-workspace onboarding redirect", async () => {
    const dashboard = await readFile(
      new URL("../app/dashboard/page.tsx", import.meta.url),
      "utf8",
    );

    assert.match(
      dashboard,
      /if \(workspaces\.length === 0\) \{\s*redirect\("\/onboarding"\);/,
    );
  });
});
