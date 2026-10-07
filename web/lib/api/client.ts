import "server-only";

import { getApiUrl } from "@/lib/api/env";
import {
  type ApiIdentity,
  type ApiWorkspace,
  isUuid,
  parseApiIdentity,
  parseApiWorkspace,
} from "@/lib/api/types";

const REQUEST_TIMEOUT_MS = 5_000;

export type ApiErrorKind =
  | "authentication"
  | "not-found"
  | "unavailable"
  | "invalid-response";

export class ApiClientError extends Error {
  constructor(
    public readonly kind: ApiErrorKind,
    public readonly status?: number,
  ) {
    super("The secure API request could not be completed.");
    this.name = "ApiClientError";
  }
}

function errorForStatus(status: number): ApiClientError {
  if (status === 401) {
    return new ApiClientError("authentication", status);
  }
  if (status === 404) {
    return new ApiClientError("not-found", status);
  }
  if (status === 503 || status >= 500) {
    return new ApiClientError("unavailable", status);
  }
  return new ApiClientError("invalid-response", status);
}

async function requestJson(path: string, accessToken: string): Promise<unknown> {
  if (!accessToken) {
    throw new ApiClientError("authentication");
  }

  const requestUrl = new URL(path, getApiUrl());
  let response: Response;

  try {
    response = await fetch(requestUrl, {
      cache: "no-store",
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${accessToken}`,
      },
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  } catch {
    throw new ApiClientError("unavailable");
  }

  if (!response.ok) {
    throw errorForStatus(response.status);
  }

  try {
    return await response.json();
  } catch {
    throw new ApiClientError("invalid-response", response.status);
  }
}

export async function getApiIdentity(
  accessToken: string,
): Promise<ApiIdentity> {
  const identity = parseApiIdentity(
    await requestJson("/v1/me", accessToken),
  );

  if (!identity) {
    throw new ApiClientError("invalid-response");
  }

  return identity;
}

export async function getApiWorkspace(
  accessToken: string,
  workspaceId: string,
): Promise<ApiWorkspace> {
  if (!isUuid(workspaceId)) {
    throw new ApiClientError("invalid-response");
  }

  const workspace = parseApiWorkspace(
    await requestJson(
      `/v1/workspaces/${encodeURIComponent(workspaceId)}`,
      accessToken,
    ),
  );

  if (!workspace) {
    throw new ApiClientError("invalid-response");
  }

  return workspace;
}
