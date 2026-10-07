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

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
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
