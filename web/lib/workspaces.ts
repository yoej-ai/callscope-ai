import type { SupabaseClient } from "@supabase/supabase-js";

export type WorkspaceSummary = {
  id: string;
  name: string;
  created_at: string;
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isWorkspaceId(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

export async function listAccessibleWorkspaces(supabase: SupabaseClient) {
  const { data, error } = await supabase
    .from("workspaces")
    .select("id, name, created_at")
    .order("created_at", { ascending: true })
    .order("id", { ascending: true });

  return {
    error,
    workspaces: (data ?? []) as WorkspaceSummary[],
  };
}

