import "server-only";

const LOCAL_HTTP_HOSTS = new Set(["127.0.0.1", "localhost"]);

export function getApiUrl(): URL {
  const configuredUrl = process.env.API_URL?.trim();

  if (!configuredUrl) {
    throw new Error("API_URL is required for protected API functionality.");
  }

  let apiUrl: URL;
  try {
    apiUrl = new URL(configuredUrl);
  } catch {
    throw new Error("API_URL must be a valid absolute URL.");
  }

  if (apiUrl.protocol !== "http:" && apiUrl.protocol !== "https:") {
    throw new Error("API_URL must use the http:// or https:// protocol.");
  }

  if (apiUrl.protocol === "http:" && !LOCAL_HTTP_HOSTS.has(apiUrl.hostname)) {
    throw new Error("API_URL may use HTTP only for local development.");
  }

  if (apiUrl.username || apiUrl.password) {
    throw new Error("API_URL must not include credentials.");
  }

  if (apiUrl.pathname !== "/" || apiUrl.search || apiUrl.hash) {
    throw new Error("API_URL must be an origin without a path, query, or fragment.");
  }

  return new URL(apiUrl.origin);
}
