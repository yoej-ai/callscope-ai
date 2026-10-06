"use server";

import { redirect } from "next/navigation";

import { createClient } from "@/lib/supabase/server";
import {
  isWorkspaceId,
  listAccessibleWorkspaces,
} from "@/lib/workspaces";

function onboardingErrorPath(error: "create-failed" | "invalid-name") {
  return `/onboarding?error=${error}`;
}

export async function createWorkspace(formData: FormData) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/sign-in?message=Please%20sign%20in%20to%20continue.");
  }

  const { workspaces, error: workspaceError } =
    await listAccessibleWorkspaces(supabase);

  if (workspaceError) {
    console.error("Unable to verify workspace onboarding state", {
      code: workspaceError.code,
    });
    redirect(onboardingErrorPath("create-failed"));
  }

  if (workspaces.length > 0) {
    redirect(`/dashboard?workspace=${encodeURIComponent(workspaces[0].id)}`);
  }

  const submittedName = formData.get("name");
  if (typeof submittedName !== "string") {
    redirect(onboardingErrorPath("invalid-name"));
  }

  const name = submittedName.trim();
  if (!name || name.length > 120) {
    redirect(onboardingErrorPath("invalid-name"));
  }

  const { data, error } = await supabase.rpc("create_workspace", {
    p_name: name,
  });

  if (error) {
    console.error("Workspace creation RPC failed", { code: error.code });
    redirect(onboardingErrorPath("create-failed"));
  }

  const createdWorkspace = Array.isArray(data) ? data[0] : null;
  const workspaceId = createdWorkspace?.workspace_id;

  if (!isWorkspaceId(workspaceId)) {
    console.error("Workspace creation RPC returned an invalid identifier");
    redirect(onboardingErrorPath("create-failed"));
  }

  redirect(`/dashboard?workspace=${encodeURIComponent(workspaceId)}`);
}

