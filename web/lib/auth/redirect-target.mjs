const DEFAULT_AUTH_REDIRECT = "/dashboard";
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f-\u009f]/u;

/** @param {string} value */
function isUnsafeAtAnyEncoding(value) {
  let candidate = value;

  for (let depth = 0; depth < 4; depth += 1) {
    if (
      !candidate.startsWith("/") ||
      candidate.startsWith("//") ||
      candidate.includes("\\") ||
      CONTROL_CHARACTERS.test(candidate)
    ) {
      return true;
    }

    let decoded;
    try {
      decoded = decodeURIComponent(candidate);
    } catch {
      return depth === 0;
    }

    if (decoded === candidate) {
      return false;
    }

    candidate = decoded;
  }

  return (
    !candidate.startsWith("/") ||
    candidate.startsWith("//") ||
    candidate.includes("\\") ||
    CONTROL_CHARACTERS.test(candidate) ||
    candidate.includes("%")
  );
}

/**
 * @param {string | URL} requestUrl
 * @param {string | null} requestedNext
 */
export function resolveSafeAuthRedirect(requestUrl, requestedNext) {
  const applicationUrl = new URL(requestUrl);
  return new URL(
    normalizeSafeAuthRedirectPath(requestedNext),
    applicationUrl.origin,
  );
}

/** @param {string | null | undefined} requestedNext */
export function normalizeSafeAuthRedirectPath(requestedNext) {
  if (typeof requestedNext !== "string") {
    return DEFAULT_AUTH_REDIRECT;
  }

  if (
    requestedNext.length === 0 ||
    requestedNext.length > 2048 ||
    isUnsafeAtAnyEncoding(requestedNext)
  ) {
    return DEFAULT_AUTH_REDIRECT;
  }

  try {
    const validationOrigin = "https://auth-redirect.invalid";
    const redirectUrl = new URL(requestedNext, validationOrigin);

    if (redirectUrl.origin !== validationOrigin) {
      return DEFAULT_AUTH_REDIRECT;
    }

    return `${redirectUrl.pathname}${redirectUrl.search}${redirectUrl.hash}`;
  } catch {
    return DEFAULT_AUTH_REDIRECT;
  }
}
