import { redirect } from "next/navigation";

import { DashboardNav } from "@/components/dashboard-nav";
import { createClient } from "@/lib/supabase/server";
import { listAccessibleWorkspaces } from "@/lib/workspaces";

type DashboardPageProps = {
  searchParams: Promise<{ workspace?: string | string[] }>;
};

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

  return (
    <div className="dashboard-shell">
      <DashboardNav email={user.email ?? "Signed-in user"} />
      <main className="dashboard-main">
        <section className="workspace-header" aria-labelledby="workspace-title">
          <div>
            <p className="eyebrow">Active workspace</p>
            <h1 id="workspace-title">{activeWorkspace.name}</h1>
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

