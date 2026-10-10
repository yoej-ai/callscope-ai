import { normalizeSafeAuthRedirectPath } from "./redirect-target.mjs";

/**
 * @param {string | URL} applicationUrl
 * @param {string | null | undefined} requestedNext
 */
export function createAuthCallbackUrl(applicationUrl, requestedNext) {
  const callbackUrl = new URL("/auth/callback", new URL(applicationUrl).origin);
  callbackUrl.searchParams.set(
    "next",
    normalizeSafeAuthRedirectPath(requestedNext),
  );
  return callbackUrl.toString();
}

/**
 * @param {string | URL} applicationUrl
 * @param {string | null | undefined} requestedNext
 */
export function createGoogleOAuthSignInOptions(applicationUrl, requestedNext) {
  return {
    provider: "google",
    options: {
      redirectTo: createAuthCallbackUrl(applicationUrl, requestedNext),
    },
  };
}
