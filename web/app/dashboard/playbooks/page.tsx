import Link from "next/link";

import { DashboardNav } from "@/components/dashboard-nav";
import {
  canManagePlaybooks,
  playbookVersionLabel,
} from "@/lib/playbooks.mjs";
import {
  loadPlaybookWorkspaceContext,
  loadWorkspacePlaybooks,
} from "@/lib/playbook-data";
import { humanizeDisplayLabel } from "@/lib/presentation/labels.mjs";

type PlaybooksPageProps = {
  searchParams: Promise<{
    workspace?: string | string[];
    notice?: string | string[];
    error?: string | string[];
  }>;
};

const NOTICES: Record<string, string> = {
  created: "Playbook draft created.",
  updated: "Playbook draft saved.",
  "criterion-added": "Criterion added.",
  "criterion-updated": "Criterion saved.",
  "criterion-removed": "Criterion removed.",
  "criterion-moved": "Criterion order updated.",
  published: "Playbook version published and locked.",
  "version-created": "A new editable version was created.",
};

const ERRORS: Record<string, string> = {
  invalid: "Check the submitted fields and try again.",
  "not-authorized": "You do not have permission to manage playbooks.",
  "save-failed": "The playbook could not be saved. Refresh and try again.",
  "publish-failed":
    "The version could not be published. Confirm its criteria total exactly 100%.",
};

export default async function PlaybooksPage({
  searchParams,
}: PlaybooksPageProps) {
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
              <h1>We could not securely load your playbooks.</h1>
              <p>Please refresh the page and try again.</p>
            </div>
          </section>
        </main>
      </div>
    );
  }

  const { playbooks, error } = await loadWorkspacePlaybooks(
    context.supabase,
    context.activeWorkspace.id,
  );
  const canManage = canManagePlaybooks(context.role);
  const notice =
    typeof parameters.notice === "string" ? NOTICES[parameters.notice] : null;
  const actionError =
    typeof parameters.error === "string" ? ERRORS[parameters.error] : null;

  return (
    <div className="dashboard-shell">
      <DashboardNav email={context.user.email ?? "Signed-in user"} />
      <main className="dashboard-main playbooks-main">
        <header className="playbooks-header">
          <div>
            <p className="eyebrow">Evaluation foundations</p>
            <h1>Playbooks</h1>
            <p className="lede">
              Define the exact, versioned criteria your team will use when call
              scoring is introduced.
            </p>
          </div>
          {canManage && (
            <Link
              className="button primary"
              href={`/dashboard/playbooks/new?workspace=${encodeURIComponent(context.activeWorkspace.id)}`}
            >
              Create playbook
            </Link>
          )}
        </header>

        <section className="playbook-workspace-bar" aria-label="Active workspace">
          <div>
            <span>Workspace</span>
            <strong>{context.activeWorkspace.name}</strong>
          </div>
          {context.workspaces.length > 1 && (
            <form action="/dashboard/playbooks" method="get">
              <label htmlFor="playbook-workspace">Switch workspace</label>
              <select
                defaultValue={context.activeWorkspace.id}
                id="playbook-workspace"
                name="workspace"
              >
                {context.workspaces.map((workspace) => (
                  <option key={workspace.id} value={workspace.id}>
                    {workspace.name}
                  </option>
                ))}
              </select>
              <button className="button ghost small" type="submit">Switch</button>
            </form>
          )}
        </section>

        {(notice || actionError) && (
          <p
            className={`playbook-message ${actionError ? "error" : "success"}`}
            role={actionError ? "alert" : "status"}
          >
            {actionError ?? notice}
          </p>
        )}

        {error || !playbooks ? (
          <section className="empty-state" role="alert">
            <div className="empty-icon" aria-hidden="true">!</div>
            <div>
              <h2>Playbooks are temporarily unavailable.</h2>
              <p>Refresh the page and try again.</p>
            </div>
          </section>
        ) : playbooks.length === 0 ? (
          <section className="playbook-empty">
            <p className="eyebrow">No playbooks yet</p>
            <h2>
              {canManage
                ? "Turn your coaching standards into a versioned playbook."
                : "No published playbooks are available yet."}
            </h2>
            <p>
              {canManage
                ? "Start with a Sales playbook, add weighted criteria, and publish only when the total reaches 100%."
                : "An owner or admin can publish a playbook for this workspace."}
            </p>
            {canManage && (
              <Link
                className="button secondary"
                href={`/dashboard/playbooks/new?workspace=${encodeURIComponent(context.activeWorkspace.id)}`}
              >
                Create the first playbook
              </Link>
            )}
          </section>
        ) : (
          <section className="playbook-grid" aria-label="Workspace playbooks">
            {playbooks.map((playbook) => {
              const latest = playbook.versions.at(-1);
              if (!latest) return null;
              const publishedCount = playbook.versions.filter(
                (version) => version.status === "published",
              ).length;
              return (
                <article className="playbook-card" key={playbook.id}>
                  <div className="playbook-card-topline">
                    <span className={`version-badge ${latest.status}`}>
                      {latest.status === "draft" ? "Draft" : "Published"}
                    </span>
                    <span>{humanizeDisplayLabel(latest.vertical)}</span>
                  </div>
                  <h2>{latest.name}</h2>
                  <p>
                    {playbookVersionLabel(latest.versionNumber, latest.status)}
                  </p>
                  <dl className="playbook-card-meta">
                    <div>
                      <dt>Criteria</dt>
                      <dd>{latest.criteria.length}</dd>
                    </div>
                    <div>
                      <dt>Published history</dt>
                      <dd>{publishedCount}</dd>
                    </div>
                  </dl>
                  <Link
                    className="text-link"
                    href={`/dashboard/playbooks/${encodeURIComponent(playbook.id)}?workspace=${encodeURIComponent(context.activeWorkspace.id)}`}
                  >
                    {latest.status === "draft" && canManage
                      ? "Continue editing →"
                      : "View playbook →"}
                  </Link>
                </article>
              );
            })}
          </section>
        )}
      </main>
    </div>
  );
}
