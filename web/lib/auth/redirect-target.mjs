const DEFAULT_AUTH_REDIRECT = "/dashboard";
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/u;

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
  const fallback = new URL(DEFAULT_AUTH_REDIRECT, applicationUrl.origin);

  if (
    requestedNext === null ||
    requestedNext.length === 0 ||
    requestedNext.length > 2048 ||
    isUnsafeAtAnyEncoding(requestedNext)
  ) {
    return fallback;
  }

  try {
    const redirectUrl = new URL(requestedNext, applicationUrl.origin);

    if (redirectUrl.origin !== applicationUrl.origin) {
      return fallback;
    }

    return redirectUrl;
  } catch {
    return fallback;
  }
}
