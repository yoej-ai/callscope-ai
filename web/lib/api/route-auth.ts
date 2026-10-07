import "server-only";

import { createClient } from "@/lib/supabase/server";
import { isWorkspaceId, listAccessibleWorkspaces } from "@/lib/workspaces";

type AuthorizedWorkspace = {
  ok: true;
  accessToken: string;
};

type WorkspaceAuthorizationFailure = {
  ok: false;
  status: 401 | 404 | 503;
  message: string;
};

export type WorkspaceAuthorization =
  | AuthorizedWorkspace
  | WorkspaceAuthorizationFailure;

export async function authorizeWorkspaceRequest(
  workspaceId: unknown,
): Promise<WorkspaceAuthorization> {
  try {
    const supabase = await createClient();
    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser();

    if (userError || !user) {
      return { ok: false, status: 401, message: "Your session has expired." };
    }

    if (!isWorkspaceId(workspaceId)) {
      return { ok: false, status: 404, message: "Workspace unavailable." };
    }

    const { workspaces, error: workspaceError } =
      await listAccessibleWorkspaces(supabase);
    if (workspaceError) {
      return {
        ok: false,
        status: 503,
        message: "Workspace service is unavailable.",
      };
    }

    if (!workspaces.some((workspace) => workspace.id === workspaceId)) {
      return { ok: false, status: 404, message: "Workspace unavailable." };
    }

    const {
      data: { session },
      error: sessionError,
    } = await supabase.auth.getSession();
    if (sessionError || !session?.access_token) {
      return { ok: false, status: 401, message: "Your session has expired." };
    }

    return { ok: true, accessToken: session.access_token };
  } catch {
    return {
      ok: false,
      status: 503,
      message: "Workspace service is unavailable.",
    };
  }
}
