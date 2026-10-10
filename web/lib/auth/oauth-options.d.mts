export type GoogleOAuthSignInOptions = {
  provider: "google";
  options: {
    redirectTo: string;
  };
};

export function createAuthCallbackUrl(
  applicationUrl: string | URL,
  requestedNext?: string | null,
): string;

export function createGoogleOAuthSignInOptions(
  applicationUrl: string | URL,
  requestedNext?: string | null,
): GoogleOAuthSignInOptions;
