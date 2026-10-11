"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import {
  isPlaybookUuid,
  normalizePlaybookName,
  normalizePlaybookVertical,
  parseCriterionInput,
} from "@/lib/playbooks.mjs";
import { createClient } from "@/lib/supabase/server";

type Notice =
  | "created"
  | "updated"
  | "criterion-added"
  | "criterion-updated"
  | "criterion-removed"
  | "criterion-moved"
  | "published"
  | "version-created";
type ActionError =
  | "invalid"
  | "not-authorized"
  | "save-failed"
  | "publish-failed";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringField(formData: FormData, name: string) {
  const value = formData.get(name);
  return typeof value === "string" ? value : null;
}

function playbookListPath(
  workspaceId: string,
  state?: { notice?: Notice; error?: ActionError },
) {
  const parameters = new URLSearchParams({ workspace: workspaceId });
  if (state?.notice) parameters.set("notice", state.notice);
  if (state?.error) parameters.set("error", state.error);
  return `/dashboard/playbooks?${parameters.toString()}`;
}

function playbookDetailPath(
  workspaceId: string,
  playbookId: string,
  state?: {
    notice?: Notice;
    error?: ActionError;
  },
) {
  const parameters = new URLSearchParams({ workspace: workspaceId });
  if (state?.notice) parameters.set("notice", state.notice);
  if (state?.error) parameters.set("error", state.error);
  return `/dashboard/playbooks/${encodeURIComponent(playbookId)}?${parameters.toString()}`;
}

async function authenticatedClient() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    redirect("/sign-in?message=Please%20sign%20in%20to%20continue.");
  }
  return supabase;
}

export async function createPlaybook(formData: FormData) {
  const workspaceId = stringField(formData, "workspaceId");
  const name = normalizePlaybookName(stringField(formData, "name"));
  const vertical = normalizePlaybookVertical(stringField(formData, "vertical"));

  if (!isPlaybookUuid(workspaceId)) {
    redirect("/dashboard/playbooks?error=invalid");
  }
  if (!name || !vertical) {
    redirect(playbookListPath(workspaceId, { error: "invalid" }));
  }

  const supabase = await authenticatedClient();
  const { data, error } = await supabase
    .rpc("create_playbook", {
      p_workspace_id: workspaceId,
      p_name: name,
      p_vertical: vertical,
    })
    .maybeSingle();

  if (
    error ||
    !isRecord(data) ||
    !isPlaybookUuid(data.playbook_id) ||
    !isPlaybookUuid(data.version_id) ||
    data.version_number !== 1
  ) {
    console.error("Playbook creation failed", { code: error?.code ?? "invalid-response" });
    redirect(playbookListPath(workspaceId, { error: "save-failed" }));
  }

  redirect(
    playbookDetailPath(workspaceId, data.playbook_id, { notice: "created" }),
  );
}

export async function updatePlaybookDraft(formData: FormData) {
  const workspaceId = stringField(formData, "workspaceId");
  const playbookId = stringField(formData, "playbookId");
  const versionId = stringField(formData, "versionId");
  const name = normalizePlaybookName(stringField(formData, "name"));
  const vertical = normalizePlaybookVertical(stringField(formData, "vertical"));

  if (
    !isPlaybookUuid(workspaceId) ||
    !isPlaybookUuid(playbookId) ||
    !isPlaybookUuid(versionId)
  ) {
    redirect("/dashboard/playbooks?error=invalid");
  }
  if (!name || !vertical) {
    redirect(playbookDetailPath(workspaceId, playbookId, { error: "invalid" }));
  }

  const supabase = await authenticatedClient();
  const { data, error } = await supabase.rpc("update_playbook_draft", {
    p_workspace_id: workspaceId,
    p_version_id: versionId,
    p_name: name,
    p_vertical: vertical,
  });

  if (error || data !== "updated") {
    console.error("Playbook draft update failed", {
      code: error?.code ?? "invalid-response",
    });
    redirect(playbookDetailPath(workspaceId, playbookId, { error: "save-failed" }));
  }
  redirect(playbookDetailPath(workspaceId, playbookId, { notice: "updated" }));
}

function criterionInput(formData: FormData) {
  return parseCriterionInput({
    name: formData.get("name"),
    description: formData.get("description"),
    weight: formData.get("weight"),
    passGuidance: formData.get("passGuidance"),
    failGuidance: formData.get("failGuidance"),
  });
}

export async function addPlaybookCriterion(formData: FormData) {
  const workspaceId = stringField(formData, "workspaceId");
  const playbookId = stringField(formData, "playbookId");
  const versionId = stringField(formData, "versionId");
  const input = criterionInput(formData);
  if (
    !isPlaybookUuid(workspaceId) ||
    !isPlaybookUuid(playbookId) ||
    !isPlaybookUuid(versionId)
  ) {
    return {
      ok: false,
      message: "Check the criterion fields and try again.",
    } as const;
  }
  if (!input) {
    return {
      ok: false,
      message: "Check the criterion fields and try again.",
    } as const;
  }

  const supabase = await authenticatedClient();
  const { data, error } = await supabase.rpc("add_playbook_criterion", {
    p_workspace_id: workspaceId,
    p_version_id: versionId,
    p_name: input.name,
    p_description: input.description,
    p_weight: input.weight,
    p_pass_guidance: input.passGuidance,
    p_fail_guidance: input.failGuidance,
  });

  if (error || !isPlaybookUuid(data)) {
    console.error("Playbook criterion creation failed", {
      code: error?.code ?? "invalid-response",
    });
    return {
      ok: false,
      message: "The criterion could not be added. Review the fields and try again.",
    } as const;
  }
  revalidatePath(`/dashboard/playbooks/${encodeURIComponent(playbookId)}`);
  revalidatePath("/dashboard/playbooks");
  return { ok: true, message: "Criterion added and saved." } as const;
}

export async function updatePlaybookCriterion(formData: FormData) {
  const workspaceId = stringField(formData, "workspaceId");
  const playbookId = stringField(formData, "playbookId");
  const criterionId = stringField(formData, "criterionId");
  const input = criterionInput(formData);
  if (
    !isPlaybookUuid(workspaceId) ||
    !isPlaybookUuid(playbookId) ||
    !isPlaybookUuid(criterionId)
  ) {
    return {
      ok: false,
      message: "Check the criterion fields and try again.",
    } as const;
  }
  if (!input) {
    return {
      ok: false,
      message: "Check the criterion fields and try again.",
    } as const;
  }

  const supabase = await authenticatedClient();
  const { data, error } = await supabase.rpc("update_playbook_criterion", {
    p_workspace_id: workspaceId,
    p_criterion_id: criterionId,
    p_name: input.name,
    p_description: input.description,
    p_weight: input.weight,
    p_pass_guidance: input.passGuidance,
    p_fail_guidance: input.failGuidance,
  });

  if (error || data !== "updated") {
    console.error("Playbook criterion update failed", {
      code: error?.code ?? "invalid-response",
    });
    return {
      ok: false,
      message: "The criterion could not be saved. Review the fields and try again.",
    } as const;
  }
  revalidatePath(`/dashboard/playbooks/${encodeURIComponent(playbookId)}`);
  revalidatePath("/dashboard/playbooks");
  return { ok: true, message: "Criterion changes saved." } as const;
}

export async function removePlaybookCriterion(formData: FormData) {
  const workspaceId = stringField(formData, "workspaceId");
  const playbookId = stringField(formData, "playbookId");
  const criterionId = stringField(formData, "criterionId");
  if (
    !isPlaybookUuid(workspaceId) ||
    !isPlaybookUuid(playbookId) ||
    !isPlaybookUuid(criterionId)
  ) {
    redirect("/dashboard/playbooks?error=invalid");
  }

  const supabase = await authenticatedClient();
  const { data, error } = await supabase.rpc("remove_playbook_criterion", {
    p_workspace_id: workspaceId,
    p_criterion_id: criterionId,
  });
  if (error || data !== "removed") {
    console.error("Playbook criterion removal failed", {
      code: error?.code ?? "invalid-response",
    });
    redirect(playbookDetailPath(workspaceId, playbookId, { error: "save-failed" }));
  }
  redirect(
    playbookDetailPath(workspaceId, playbookId, {
      notice: "criterion-removed",
    }),
  );
}

export async function movePlaybookCriterion(formData: FormData) {
  const workspaceId = stringField(formData, "workspaceId");
  const playbookId = stringField(formData, "playbookId");
  const criterionId = stringField(formData, "criterionId");
  const direction = stringField(formData, "direction");
  if (
    !isPlaybookUuid(workspaceId) ||
    !isPlaybookUuid(playbookId) ||
    !isPlaybookUuid(criterionId) ||
    (direction !== "up" && direction !== "down")
  ) {
    redirect("/dashboard/playbooks?error=invalid");
  }

  const supabase = await authenticatedClient();
  const { data, error } = await supabase.rpc("move_playbook_criterion", {
    p_workspace_id: workspaceId,
    p_criterion_id: criterionId,
    p_direction: direction,
  });
  if (error || (data !== "moved" && data !== "unchanged")) {
    console.error("Playbook criterion reorder failed", {
      code: error?.code ?? "invalid-response",
    });
    redirect(playbookDetailPath(workspaceId, playbookId, { error: "save-failed" }));
  }
  redirect(
    playbookDetailPath(workspaceId, playbookId, { notice: "criterion-moved" }),
  );
}

export async function publishPlaybookVersion(formData: FormData) {
  const workspaceId = stringField(formData, "workspaceId");
  const playbookId = stringField(formData, "playbookId");
  const versionId = stringField(formData, "versionId");
  if (
    !isPlaybookUuid(workspaceId) ||
    !isPlaybookUuid(playbookId) ||
    !isPlaybookUuid(versionId)
  ) {
    return {
      ok: false,
      message: "The publish request was invalid. Refresh and try again.",
    } as const;
  }

  const supabase = await authenticatedClient();
  const { data, error } = await supabase.rpc("publish_playbook_version", {
    p_workspace_id: workspaceId,
    p_version_id: versionId,
  });
  if (error || data !== "published") {
    console.error("Playbook publication failed", {
      code: error?.code ?? "invalid-response",
    });
    return {
      ok: false,
      message:
        "Publishing was blocked. Check the saved criteria and try again.",
    } as const;
  }
  revalidatePath(`/dashboard/playbooks/${encodeURIComponent(playbookId)}`);
  revalidatePath("/dashboard/playbooks");
  return { ok: true, message: "Version published." } as const;
}

export async function createNextPlaybookVersion(formData: FormData) {
  const workspaceId = stringField(formData, "workspaceId");
  const playbookId = stringField(formData, "playbookId");
  if (!isPlaybookUuid(workspaceId) || !isPlaybookUuid(playbookId)) {
    redirect("/dashboard/playbooks?error=invalid");
  }

  const supabase = await authenticatedClient();
  const { data, error } = await supabase
    .rpc("create_next_playbook_version", {
      p_workspace_id: workspaceId,
      p_playbook_id: playbookId,
    })
    .maybeSingle();

  if (
    error ||
    !isRecord(data) ||
    !isPlaybookUuid(data.version_id) ||
    !Number.isSafeInteger(data.version_number) ||
    (data.version_number as number) < 2
  ) {
    console.error("Playbook version creation failed", {
      code: error?.code ?? "invalid-response",
    });
    redirect(playbookDetailPath(workspaceId, playbookId, { error: "save-failed" }));
  }
  redirect(
    `${playbookDetailPath(workspaceId, playbookId, {
      notice: "version-created",
    })}#draft-editor-title`,
  );
}
