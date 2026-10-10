import Link from "next/link";
import { redirect } from "next/navigation";

import { createPlaybook } from "@/app/dashboard/playbooks/actions";
import { DashboardNav } from "@/components/dashboard-nav";
import { PlaybookPendingButton } from "@/components/playbook-controls";
import { canManagePlaybooks } from "@/lib/playbooks.mjs";
import { loadPlaybookWorkspaceContext } from "@/lib/playbook-data";

type NewPlaybookPageProps = {
  searchParams: Promise<{ workspace?: string | string[] }>;
};

export default async function NewPlaybookPage({
  searchParams,
}: NewPlaybookPageProps) {
  const parameters = await searchParams;
  const context = await loadPlaybookWorkspaceContext(
    typeof parameters.workspace === "string" ? parameters.workspace : null,
  );

  if (!context) {
    return (
      <div className="dashboard-shell">
        <DashboardNav email="Signed-in user" />
        <main className="dashboard-main">
          <section className="empty-state" role="alert">
            <div className="empty-icon" aria-hidden="true">!</div>
            <div>
              <h1>We could not verify this workspace.</h1>
              <p>Please return to Playbooks and try again.</p>
            </div>
          </section>
        </main>
      </div>
    );
  }

  if (!canManagePlaybooks(context.role)) {
    redirect(
      `/dashboard/playbooks?workspace=${encodeURIComponent(context.activeWorkspace.id)}&error=not-authorized`,
    );
  }

  const backHref = `/dashboard/playbooks?workspace=${encodeURIComponent(context.activeWorkspace.id)}`;
  return (
    <div className="dashboard-shell">
      <DashboardNav email={context.user.email ?? "Signed-in user"} />
      <main className="dashboard-main playbook-form-main">
        <Link className="text-link back-link" href={backHref}>
          ← Back to playbooks
        </Link>
        <section className="playbook-form-card" aria-labelledby="new-playbook-title">
          <p className="eyebrow">New evaluation foundation</p>
          <h1 id="new-playbook-title">Create a playbook</h1>
          <p className="lede">
            Version 1 starts as a private draft. Add criteria and publish only
            when the weights total exactly 100%.
          </p>
          <form action={createPlaybook} className="playbook-form">
            <input
              name="workspaceId"
              type="hidden"
              value={context.activeWorkspace.id}
            />
            <label htmlFor="playbook-name">Playbook name</label>
            <input
              autoComplete="off"
              id="playbook-name"
              maxLength={120}
              name="name"
              placeholder="Sales discovery"
              required
            />
            <label htmlFor="playbook-vertical">Vertical</label>
            <select defaultValue="sales" id="playbook-vertical" name="vertical">
              <option value="sales">Sales</option>
            </select>
            <p className="field-note">
              Additional verticals can be introduced later without changing
              published versions.
            </p>
            <div className="playbook-form-actions">
              <Link className="button ghost" href={backHref}>Cancel</Link>
              <PlaybookPendingButton
                idleLabel="Create draft"
                pendingLabel="Creating draft…"
              />
            </div>
          </form>
        </section>
      </main>
    </div>
  );
}
