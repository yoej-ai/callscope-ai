import { redirect } from "next/navigation";

import {
  ApiClientError,
  type ApiErrorKind,
  getApiIdentity,
  getApiWorkspace,
} from "@/lib/api/client";
import { DashboardNav } from "@/components/dashboard-nav";
import { createClient } from "@/lib/supabase/server";
import { listAccessibleWorkspaces } from "@/lib/workspaces";

type DashboardPageProps = {
  searchParams: Promise<{ workspace?: string | string[] }>;
};

type DashboardApiErrorProps = {
  email: string;
  kind: Exclude<ApiErrorKind, "authentication">;
};

function DashboardApiError({ email, kind }: DashboardApiErrorProps) {
  const unavailable = kind === "unavailable";

  return (
    <div className="dashboard-shell">
      <DashboardNav email={email} />
      <main className="dashboard-main">
        <section className="empty-state" role="alert">
          <div className="empty-icon" aria-hidden="true">
            !
          </div>
          <div>
            <h1>
              {unavailable
                ? "The secure workspace service is temporarily unavailable."
                : "We could not securely load this workspace."}
            </h1>
            <p>Please refresh the page and try again.</p>
          </div>
        </section>
      </main>
    </div>
  );
}

export default async function DashboardPage({
  searchParams,
}: DashboardPageProps) {
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
    console.error("Unable to load dashboard workspaces", {
      code: workspaceError.code,
    });

    return (
      <div className="dashboard-shell">
        <DashboardNav email={user.email ?? "Signed-in user"} />
        <main className="dashboard-main">
          <section className="empty-state" role="alert">
            <div className="empty-icon" aria-hidden="true">
              !
            </div>
            <div>
              <h1>We could not load your workspaces.</h1>
              <p>Please refresh the page and try again.</p>
            </div>
          </section>
        </main>
      </div>
    );
  }

  if (workspaces.length === 0) {
    redirect("/onboarding");
  }

  const { workspace: requestedWorkspace } = await searchParams;
  const requestedWorkspaceId =
    typeof requestedWorkspace === "string" ? requestedWorkspace : undefined;
  const activeWorkspace =
    workspaces.find((workspace) => workspace.id === requestedWorkspaceId) ??
    workspaces[0];

  const {
    data: { session },
    error: sessionError,
  } = await supabase.auth.getSession();

  if (sessionError || !session?.access_token) {
    redirect(
      "/sign-in?message=Your%20session%20could%20not%20be%20verified.%20Please%20sign%20in%20again.",
    );
  }

  let apiIdentity;
  try {
    apiIdentity = await getApiIdentity(session.access_token);
  } catch (error) {
    if (error instanceof ApiClientError) {
      if (error.kind === "authentication") {
        redirect(
          "/sign-in?message=Your%20session%20could%20not%20be%20verified.%20Please%20sign%20in%20again.",
        );
      }

      console.error("Secure API identity verification failed", {
        kind: error.kind,
        status: error.status,
      });
      return (
        <DashboardApiError
          email={user.email ?? "Signed-in user"}
          kind={error.kind}
        />
      );
    }

    console.error("Secure API identity verification failed unexpectedly");
    return (
      <DashboardApiError
        email={user.email ?? "Signed-in user"}
        kind="invalid-response"
      />
    );
  }

  if (apiIdentity.user_id !== user.id) {
    console.error("Secure API identity did not match the trusted user");
    return (
      <DashboardApiError
        email={user.email ?? "Signed-in user"}
        kind="invalid-response"
      />
    );
  }

  let apiWorkspace;
  try {
    apiWorkspace = await getApiWorkspace(
      session.access_token,
      activeWorkspace.id,
    );
  } catch (error) {
    if (error instanceof ApiClientError) {
      if (error.kind === "authentication") {
        redirect(
          "/sign-in?message=Your%20session%20could%20not%20be%20verified.%20Please%20sign%20in%20again.",
        );
      }

      console.error("Secure workspace lookup failed", {
        kind: error.kind,
        status: error.status,
        workspaceId: activeWorkspace.id,
      });
      return (
        <DashboardApiError
          email={user.email ?? "Signed-in user"}
          kind={error.kind}
        />
      );
    }

    console.error("Secure workspace lookup failed unexpectedly", {
      workspaceId: activeWorkspace.id,
    });
    return (
      <DashboardApiError
        email={user.email ?? "Signed-in user"}
        kind="invalid-response"
      />
    );
  }

  if (apiWorkspace.id !== activeWorkspace.id) {
    console.error("Secure API workspace did not match the requested workspace");
    return (
      <DashboardApiError
        email={user.email ?? "Signed-in user"}
        kind="invalid-response"
      />
    );
  }

  return (
    <div className="dashboard-shell">
      <DashboardNav email={user.email ?? "Signed-in user"} />
      <main className="dashboard-main">
        <section className="workspace-header" aria-labelledby="workspace-title">
          <div>
            <p className="eyebrow">Active workspace</p>
            <h1 id="workspace-title">{apiWorkspace.name}</h1>
          </div>
          <form action="/dashboard" className="workspace-switcher" method="get">
            <label htmlFor="workspace">Switch workspace</label>
            <div>
              <select
                className="workspace-select"
                defaultValue={activeWorkspace.id}
                id="workspace"
                name="workspace"
              >
                {workspaces.map((workspace) => (
                  <option key={workspace.id} value={workspace.id}>
                    {workspace.name}
                  </option>
                ))}
              </select>
              <button className="button secondary small" type="submit">
                Open
              </button>
            </div>
          </form>
        </section>
        <p className="lede">
          Your workspace is ready. Call ingestion and AI analysis are not enabled
          in this phase.
        </p>
        <section className="empty-state" aria-labelledby="empty-title">
          <div className="empty-icon" aria-hidden="true">
            ◌
          </div>
          <div>
            <h2 id="empty-title">No calls yet</h2>
            <p>
              Audio upload is not enabled yet. Future call data will remain
              scoped to this workspace through database Row Level Security.
            </p>
          </div>
        </section>
      </main>
    </div>
  );
}

