import { NextResponse } from "next/server";

import { validateAudioFileMetadata } from "@/lib/audio-files";
import {
  ApiClientError,
  initiateApiCallUpload,
} from "@/lib/api/client";
import { authorizeWorkspaceRequest } from "@/lib/api/route-auth";

const NO_STORE_HEADERS = { "Cache-Control": "no-store, max-age=0" };
const EXPECTED_BODY_KEYS = ["content_type", "filename", "size_bytes"];

type RouteContext = {
  params: Promise<{ workspaceId: string }>;
};

function safeJson(body: unknown, status: number) {
  return NextResponse.json(body, { status, headers: NO_STORE_HEADERS });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactBodyKeys(value: Record<string, unknown>) {
  const keys = Object.keys(value).sort();
  return (
    keys.length === EXPECTED_BODY_KEYS.length &&
    keys.every((key, index) => key === EXPECTED_BODY_KEYS[index])
  );
}

function apiFailure(error: ApiClientError) {
  if (error.kind === "authentication") {
    return safeJson({ error: "Your session has expired." }, 401);
  }
  if (error.kind === "not-found") {
    return safeJson({ error: "Workspace unavailable." }, 404);
  }
  return safeJson({ error: "Could not prepare the secure upload." }, 503);
}

export async function POST(request: Request, context: RouteContext) {
  const { workspaceId } = await context.params;
  const authorization = await authorizeWorkspaceRequest(workspaceId);
  if (!authorization.ok) {
    return safeJson({ error: authorization.message }, authorization.status);
  }

  if (!request.headers.get("content-type")?.toLowerCase().startsWith("application/json")) {
    return safeJson({ error: "Invalid upload request." }, 400);
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return safeJson({ error: "Invalid upload request." }, 400);
  }

  if (!isRecord(body) || !hasExactBodyKeys(body)) {
    return safeJson({ error: "Invalid upload request." }, 400);
  }

  const validation = validateAudioFileMetadata(body.filename, body.size_bytes);
  if (
    !validation.ok ||
    body.content_type !== validation.value.contentType
  ) {
    return safeJson({ error: "Unsupported file metadata." }, 400);
  }

  try {
    const upload = await initiateApiCallUpload(
      authorization.accessToken,
      workspaceId,
      {
        filename: body.filename as string,
        content_type: validation.value.contentType,
        size_bytes: body.size_bytes as number,
      },
    );
    return safeJson(upload, 201);
  } catch (error) {
    if (error instanceof ApiClientError) {
      return apiFailure(error);
    }
    return safeJson({ error: "Could not prepare the secure upload." }, 503);
  }
}
