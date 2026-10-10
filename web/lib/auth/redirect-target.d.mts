export function resolveSafeAuthRedirect(
  requestUrl: string | URL,
  requestedNext: string | null,
): URL;

export function normalizeSafeAuthRedirectPath(
  requestedNext: string | null | undefined,
): string;
