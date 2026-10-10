export function completeAuthCallback(
  requestUrl: string | URL,
  applicationUrl: string | URL,
  exchangeAuthorizationCode: (code: string) => Promise<boolean>,
): Promise<URL>;
