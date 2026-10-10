import {
  normalizeSafeAuthRedirectPath,
  resolveSafeAuthRedirect,
} from "./redirect-target.mjs";

const GENERIC_CALLBACK_ERROR =
  "Authentication could not be completed. Please try again.";
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f-\u009f]/u;

/**
 * @param {URL} requestUrl
 * @param {URL} applicationUrl
 */
function callbackFailureUrl(requestUrl, applicationUrl) {
  const failureUrl = new URL("/sign-in", applicationUrl.origin);
  failureUrl.searchParams.set("message", GENERIC_CALLBACK_ERROR);
  failureUrl.searchParams.set(
    "next",
    normalizeSafeAuthRedirectPath(requestUrl.searchParams.get("next")),
  );
  return failureUrl;
}

/** @param {string | null} code */
function isValidAuthorizationCode(code) {
  return (
    typeof code === "string" &&
    code.length > 0 &&
    code.length <= 4096 &&
    !CONTROL_CHARACTERS.test(code)
  );
}

/**
 * @param {string | URL} requestUrlValue
 * @param {string | URL} applicationUrlValue
 * @param {(code: string) => Promise<boolean>} exchangeAuthorizationCode
 */
export async function completeAuthCallback(
  requestUrlValue,
  applicationUrlValue,
  exchangeAuthorizationCode,
) {
  const requestUrl = new URL(requestUrlValue);
  const applicationUrl = new URL(applicationUrlValue);
  const hasProviderError = ["error", "error_code", "error_description"].some(
    (parameter) => requestUrl.searchParams.has(parameter),
  );
  const code = requestUrl.searchParams.get("code");

  if (hasProviderError || !isValidAuthorizationCode(code)) {
    return callbackFailureUrl(requestUrl, applicationUrl);
  }

  try {
    if (!(await exchangeAuthorizationCode(code))) {
      return callbackFailureUrl(requestUrl, applicationUrl);
    }
  } catch {
    return callbackFailureUrl(requestUrl, applicationUrl);
  }

  return resolveSafeAuthRedirect(
    applicationUrl,
    requestUrl.searchParams.get("next"),
  );
}
