import "server-only";

import {
  createAuthCallbackUrl,
  createGoogleOAuthSignInOptions,
} from "@/lib/auth/oauth-options.mjs";

const DEVELOPMENT_APP_URL = "http://localhost:3000";

export function getAppUrl(): URL {
  const configuredUrl = process.env.APP_URL?.trim();

  if (!configuredUrl) {
    if (process.env.NODE_ENV === "development") {
      return new URL(DEVELOPMENT_APP_URL);
    }

    throw new Error(
      "APP_URL must be configured as an absolute http:// or https:// URL outside development.",
    );
  }

  let appUrl: URL;
  try {
    appUrl = new URL(configuredUrl);
  } catch {
    throw new Error("APP_URL must be a valid absolute URL.");
  }

  if (appUrl.protocol !== "http:" && appUrl.protocol !== "https:") {
    throw new Error("APP_URL must use the http:// or https:// protocol.");
  }

  if (appUrl.username || appUrl.password) {
    throw new Error("APP_URL must not include credentials.");
  }

  if (appUrl.pathname !== "/" || appUrl.search || appUrl.hash) {
    throw new Error("APP_URL must be an origin without a path, query, or fragment.");
  }

  return appUrl;
}

export function getAuthCallbackUrl(next?: string | null): string {
  return createAuthCallbackUrl(getAppUrl(), next);
}

export function getGoogleOAuthOptions(next?: string | null) {
  return createGoogleOAuthSignInOptions(getAppUrl(), next);
}
