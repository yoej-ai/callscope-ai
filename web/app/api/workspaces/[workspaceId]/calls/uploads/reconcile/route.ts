import { NextResponse } from "next/server";

import { ApiClientError, reconcileApiCallUploads } from "@/lib/api/client";
import { authorizeWorkspaceRequest } from "@/lib/api/route-auth";

const NO_STORE_HEADERS = { "Cache-Control": "no-store, max-age=0" };

type RouteContext = {
  params: Promise<{ workspaceId: string }>;
};

function safeJson(body: unknown, status: number) {
  return NextResponse.json(body, { status, headers: NO_STORE_HEADERS });
}

function apiFailure(error: ApiClientError) {
  if (error.kind === "authentication") {
    return safeJson({ error: "Your session has expired." }, 401);
  }
  if (error.kind === "not-found") {
    return safeJson({ error: "Workspace unavailable." }, 404);
  }
  return safeJson({ error: "Upload recovery is unavailable." }, 503);
}

export async function POST(request: Request, context: RouteContext) {
  const { workspaceId } = await context.params;
  const authorization = await authorizeWorkspaceRequest(workspaceId);
  if (!authorization.ok) {
    return safeJson({ error: authorization.message }, authorization.status);
  }

  if (!request.headers.get("content-type")?.toLowerCase().startsWith("application/json")) {
    return safeJson({ error: "Invalid recovery request." }, 400);
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return safeJson({ error: "Invalid recovery request." }, 400);
  }

  if (
    typeof body !== "object" ||
    body === null ||
    Array.isArray(body) ||
    Object.keys(body).length !== 0
  ) {
    return safeJson({ error: "Invalid recovery request." }, 400);
  }

  try {
    const result = await reconcileApiCallUploads(
      authorization.accessToken,
      workspaceId,
    );
    return safeJson(result, 200);
  } catch (error) {
    if (error instanceof ApiClientError) {
      return apiFailure(error);
    }
    return safeJson({ error: "Upload recovery is unavailable." }, 503);
  }
}
