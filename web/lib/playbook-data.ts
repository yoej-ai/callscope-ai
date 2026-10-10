import "server-only";

import { redirect } from "next/navigation";
import type { SupabaseClient, User } from "@supabase/supabase-js";

import {
  parsePlaybookData,
  parseWorkspaceRole,
  type Playbook,
  type WorkspaceRole,
} from "@/lib/playbooks.mjs";
import { createClient } from "@/lib/supabase/server";
import {
  isWorkspaceId,
  listAccessibleWorkspaces,
  type WorkspaceSummary,
} from "@/lib/workspaces";

export type PlaybookWorkspaceContext = {
  supabase: SupabaseClient;
  user: User;
  workspaces: WorkspaceSummary[];
  activeWorkspace: WorkspaceSummary;
  role: WorkspaceRole;
};

export async function loadPlaybookWorkspaceContext(
  requestedWorkspaceId: unknown,
): Promise<PlaybookWorkspaceContext | null> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/sign-in?message=Please%20sign%20in%20to%20continue.");
  }

  const { workspaces, error } = await listAccessibleWorkspaces(supabase);
  if (error) {
    console.error("Unable to load playbook workspaces", { code: error.code });
    return null;
  }

  if (workspaces.length === 0) redirect("/onboarding");

  const activeWorkspace = isWorkspaceId(requestedWorkspaceId)
    ? workspaces.find((workspace) => workspace.id === requestedWorkspaceId) ??
      workspaces[0]
    : workspaces[0];

  const { data: membership, error: membershipError } = await supabase
    .from("workspace_members")
    .select("role")
    .eq("workspace_id", activeWorkspace.id)
    .eq("user_id", user.id)
    .maybeSingle();
  const role = parseWorkspaceRole(membership?.role);

  if (membershipError || !role) {
    console.error("Unable to verify playbook workspace role", {
      code: membershipError?.code ?? "invalid-role",
    });
    return null;
  }

  return { supabase, user, workspaces, activeWorkspace, role };
}

async function loadVersionAndCriterionRows(
  supabase: SupabaseClient,
  playbookIds: string[],
) {
  if (playbookIds.length === 0) {
    return { versions: [], criteria: [], error: null };
  }

  const { data: versions, error: versionError } = await supabase
    .from("playbook_versions")
    .select(
      "id, playbook_id, version_number, status, name, vertical, created_at, updated_at, published_at",
    )
    .in("playbook_id", playbookIds)
    .order("version_number", { ascending: true })
    .limit(1000);

  if (versionError) {
    return { versions: [], criteria: [], error: versionError };
  }

  const versionIds = (versions ?? []).map((version) => version.id);
  if (versionIds.length === 0) {
    return { versions: versions ?? [], criteria: [], error: null };
  }

  const { data: criteria, error: criteriaError } = await supabase
    .from("playbook_criteria")
    .select(
      "id, playbook_version_id, name, description, weight, pass_guidance, fail_guidance, position",
    )
    .in("playbook_version_id", versionIds)
    .order("position", { ascending: true })
    .limit(2000);

  return {
    versions: versions ?? [],
    criteria: criteria ?? [],
    error: criteriaError,
  };
}

export async function loadWorkspacePlaybooks(
  supabase: SupabaseClient,
  workspaceId: string,
): Promise<{ playbooks: Playbook[] | null; error: boolean }> {
  const { data: playbooks, error: playbookError } = await supabase
    .from("playbooks")
    .select("id, workspace_id, created_at")
    .eq("workspace_id", workspaceId)
    .order("created_at", { ascending: true })
    .order("id", { ascending: true })
    .limit(100);

  if (playbookError) {
    console.error("Unable to load workspace playbooks", {
      code: playbookError.code,
    });
    return { playbooks: null, error: true };
  }

  const related = await loadVersionAndCriterionRows(
    supabase,
    (playbooks ?? []).map((playbook) => playbook.id),
  );
  if (related.error) {
    console.error("Unable to load playbook versions", {
      code: related.error.code,
    });
    return { playbooks: null, error: true };
  }

  const parsed = parsePlaybookData(
    {
      playbooks: playbooks ?? [],
      versions: related.versions,
      criteria: related.criteria,
    },
    workspaceId,
  );
  if (!parsed) {
    console.error("Playbook database response failed validation");
    return { playbooks: null, error: true };
  }

  return { playbooks: parsed, error: false };
}

export async function loadPlaybookDetail(
  supabase: SupabaseClient,
  workspaceId: string,
  playbookId: string,
): Promise<{ playbook: Playbook | null; error: boolean }> {
  const { data: playbook, error: playbookError } = await supabase
    .from("playbooks")
    .select("id, workspace_id, created_at")
    .eq("workspace_id", workspaceId)
    .eq("id", playbookId)
    .maybeSingle();

  if (playbookError) {
    console.error("Unable to load playbook", { code: playbookError.code });
    return { playbook: null, error: true };
  }
  if (!playbook) return { playbook: null, error: false };

  const related = await loadVersionAndCriterionRows(supabase, [playbookId]);
  if (related.error) {
    console.error("Unable to load playbook detail", { code: related.error.code });
    return { playbook: null, error: true };
  }

  const parsed = parsePlaybookData(
    {
      playbooks: [playbook],
      versions: related.versions,
      criteria: related.criteria,
    },
    workspaceId,
  );
  if (!parsed || parsed.length !== 1) {
    console.error("Playbook detail response failed validation");
    return { playbook: null, error: true };
  }

  return { playbook: parsed[0], error: false };
}
