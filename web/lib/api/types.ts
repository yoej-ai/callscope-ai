import "server-only";

export type ApiIdentity = {
  user_id: string;
  role: "authenticated";
};

export type ApiWorkspace = {
  id: string;
  name: string;
  created_at: string;
};

export type ApiSignedCallUpload = {
  call_id: string;
  bucket: "call-audio";
  path: string;
  upload_token: string;
  expires_in_seconds: 7200;
};

export type ApiCompletedCallUpload = {
  call_id: string;
  status: "uploaded";
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, expectedKeys: string[]) {
  const keys = Object.keys(value).sort();
  return (
    keys.length === expectedKeys.length &&
    keys.every((key, index) => key === [...expectedKeys].sort()[index])
  );
}

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

export function parseApiIdentity(value: unknown): ApiIdentity | null {
  if (
    !isRecord(value) ||
    !isUuid(value.user_id) ||
    value.role !== "authenticated"
  ) {
    return null;
  }

  return { user_id: value.user_id, role: value.role };
}

export function parseApiWorkspace(value: unknown): ApiWorkspace | null {
  if (
    !isRecord(value) ||
    !isUuid(value.id) ||
    typeof value.name !== "string" ||
    !value.name.trim() ||
    typeof value.created_at !== "string" ||
    Number.isNaN(Date.parse(value.created_at))
  ) {
    return null;
  }

  return {
    id: value.id,
    name: value.name,
    created_at: value.created_at,
  };
}

export function parseApiSignedCallUpload(
  value: unknown,
  expectedWorkspaceId: string,
): ApiSignedCallUpload | null {
  if (
    !isRecord(value) ||
    !hasExactKeys(value, [
      "bucket",
      "call_id",
      "expires_in_seconds",
      "path",
      "upload_token",
    ]) ||
    !isUuid(value.call_id) ||
    value.bucket !== "call-audio" ||
    typeof value.path !== "string" ||
    typeof value.upload_token !== "string" ||
    !value.upload_token ||
    value.upload_token.length > 8192 ||
    /[\u0000-\u001f\u007f]/.test(value.upload_token) ||
    value.expires_in_seconds !== 7200
  ) {
    return null;
  }

  const pathSegments = value.path.split("/");
  if (
    pathSegments.length !== 3 ||
    pathSegments[0] !== expectedWorkspaceId ||
    pathSegments[1] !== value.call_id ||
    !/^source\.(mp3|mp4|m4a|wav|webm|ogg)$/.test(pathSegments[2])
  ) {
    return null;
  }

  return {
    call_id: value.call_id,
    bucket: value.bucket,
    path: value.path,
    upload_token: value.upload_token,
    expires_in_seconds: value.expires_in_seconds,
  };
}

export function parseApiCompletedCallUpload(
  value: unknown,
  expectedCallId: string,
): ApiCompletedCallUpload | null {
  if (
    !isRecord(value) ||
    !hasExactKeys(value, ["call_id", "status"]) ||
    !isUuid(value.call_id) ||
    value.call_id !== expectedCallId ||
    value.status !== "uploaded"
  ) {
    return null;
  }

  return { call_id: value.call_id, status: value.status };
}
