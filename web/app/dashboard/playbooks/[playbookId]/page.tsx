import Link from "next/link";
import { notFound } from "next/navigation";

import {
  createNextPlaybookVersion,
  publishPlaybookVersion,
  updatePlaybookDraft,
} from "@/app/dashboard/playbooks/actions";
import { DashboardNav } from "@/components/dashboard-nav";
import {
  DraftCriteriaEditor,
  LivePlaybookWeights,
  PlaybookPendingButton,
  PublishPlaybookControl,
} from "@/components/playbook-controls";
import {
  PreviousVersionHistory,
  PublishedCriteriaList,
} from "@/components/published-playbook-history";
import {
  canEditPlaybookVersion,
  canManagePlaybooks,
  isPlaybookUuid,
  PLAYBOOK_LIMITS,
  publishedPlaybookEditAction,
  publishedVersionPresentation,
  totalCriterionWeight,
  validateCriteriaForPublish,
  type PlaybookVersion,
} from "@/lib/playbooks.mjs";
import {
  loadPlaybookDetail,
  loadPlaybookWorkspaceContext,
} from "@/lib/playbook-data";
import { humanizeDisplayLabel } from "@/lib/presentation/labels.mjs";

type PlaybookDetailPageProps = {
  params: Promise<{ playbookId: string }>;
  searchParams: Promise<{
    workspace?: string | string[];
    notice?: string | string[];
    error?: string | string[];
  }>;
};

const NOTICES: Record<string, string> = {
  created: "Version 1 draft created. Add your scoring criteria next.",
  updated: "Draft details saved.",
  "criterion-added": "Criterion added to the draft.",
  "criterion-updated": "Criterion changes saved.",
  "criterion-removed": "Criterion removed and the order closed up.",
  "criterion-moved": "Criterion order updated.",
  published: "Version published. Its definition is now permanently read-only.",
  "version-created": "A new draft was copied from the latest published version.",
};

const ERRORS: Record<string, string> = {
  invalid: "Check every field, weight, and identifier before trying again.",
  "save-failed": "The change could not be saved. Refresh and try again.",
  "publish-failed":
    "Publishing was blocked. Confirm there are 1–20 unique criteria in order and the weights total exactly 100%.",
};

function formatDate(value: string) {
  return new Intl.DateTimeFormat("en-AU", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}

function hiddenIdentityFields({
  workspaceId,
  playbookId,
  versionId,
  criterionId,
}: {
  workspaceId: string;
  playbookId: string;
  versionId?: string;
  criterionId?: string;
}) {
  return (
    <>
      <input name="workspaceId" type="hidden" value={workspaceId} />
      <input name="playbookId" type="hidden" value={playbookId} />
      {versionId && <input name="versionId" type="hidden" value={versionId} />}
      {criterionId && (
        <input name="criterionId" type="hidden" value={criterionId} />
      )}
    </>
  );
}

function CurrentPublishedDefinition({ version }: { version: PlaybookVersion }) {
  return (
    <section
      aria-labelledby="current-playbook-definition-title"
      className="current-version-section"
    >
      <header>
        <div>
          <p className="eyebrow">Current playbook definition</p>
          <h2 id="current-playbook-definition-title">Scoring criteria</h2>
          <p>
            Current version: Version {version.versionNumber} · {" "}
            {humanizeDisplayLabel(version.vertical)}
          </p>
        </div>
        <div className="published-lock">
          <span aria-hidden="true">✓</span>
          Read-only
        </div>
      </header>
      <p className="published-date">
        Published {version.publishedAt ? formatDate(version.publishedAt) : ""}
      </p>
      <PublishedCriteriaList criteria={version.criteria} />
    </section>
  );
}

export default async function PlaybookDetailPage({
  params,
  searchParams,
}: PlaybookDetailPageProps) {
  const [{ playbookId }, parameters] = await Promise.all([params, searchParams]);
  if (!isPlaybookUuid(playbookId)) notFound();

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
              <h1>We could not securely load this playbook.</h1>
              <p>Please return to Playbooks and try again.</p>
            </div>
          </section>
        </main>
      </div>
    );
  }

  const detail = await loadPlaybookDetail(
    context.supabase,
    context.activeWorkspace.id,
    playbookId,
  );
  if (!detail.error && !detail.playbook) notFound();
  if (detail.error || !detail.playbook) {
    return (
      <div className="dashboard-shell">
        <DashboardNav email={context.user.email ?? "Signed-in user"} />
        <main className="dashboard-main">
          <section className="empty-state" role="alert">
            <div className="empty-icon" aria-hidden="true">!</div>
            <div>
              <h1>This playbook is temporarily unavailable.</h1>
              <p>Refresh the page and try again.</p>
            </div>
          </section>
        </main>
      </div>
    );
  }

  const playbook = detail.playbook;
  const canManage = canManagePlaybooks(context.role);
  const draft = playbook.versions.find((version) => version.status === "draft");
  const {
    current: currentPublished,
    previous: previousPublished,
  } = publishedVersionPresentation(playbook.versions);
  const displayVersion = draft ?? currentPublished;
  if (!displayVersion) notFound();
  const historicalVersions = draft
    ? currentPublished
      ? [currentPublished, ...previousPublished]
      : previousPublished
    : previousPublished;
  const editAction = publishedPlaybookEditAction(
    context.role,
    currentPublished !== null,
    draft?.versionNumber ?? null,
  );

  const publishValidation = draft
    ? validateCriteriaForPublish(draft.criteria)
    : null;
  const publishMessage = !draft
    ? "No draft is available."
    : publishValidation?.reason === "count"
      ? "Add at least one criterion before publishing."
      : publishValidation?.reason === "weight"
        ? `Saved weights total ${publishValidation.totalWeight}%. They must total exactly 100%.`
        : publishValidation?.reason === "duplicate"
          ? "Criterion names must be unique."
          : publishValidation?.reason === "order"
            ? "Criterion positions must form a complete sequence."
            : publishValidation?.reason === "field"
              ? "Every criterion needs a valid name and weight."
              : "Ready to publish.";

  const notice =
    typeof parameters.notice === "string" ? NOTICES[parameters.notice] : null;
  const actionError =
    typeof parameters.error === "string" ? ERRORS[parameters.error] : null;
  const listHref = `/dashboard/playbooks?workspace=${encodeURIComponent(context.activeWorkspace.id)}`;

  return (
    <div className="dashboard-shell">
      <DashboardNav email={context.user.email ?? "Signed-in user"} />
      <main className="dashboard-main playbook-detail-main">
        <Link className="text-link back-link" href={listHref}>
          ← Back to playbooks
        </Link>

        <header className="playbook-detail-header">
          <div>
            <div className="playbook-title-status">
              <span className={`version-badge ${displayVersion.status}`}>
                {draft ? "Draft" : "Published"}
              </span>
              <span>
                {draft
                  ? currentPublished
                    ? `Draft based on Version ${currentPublished.versionNumber}`
                    : "First draft"
                  : `Current version: Version ${displayVersion.versionNumber}`}
              </span>
            </div>
            <h1>{draft ? `Editing ${draft.name}` : displayVersion.name}</h1>
            <p className="lede">
              {humanizeDisplayLabel(displayVersion.vertical)} playbook · {context.activeWorkspace.name}
              {draft && (
                <> · Changes will become the next published version when you publish.</>
              )}
            </p>
          </div>
          {editAction?.kind === "create" && (
            <form action={createNextPlaybookVersion}>
              {hiddenIdentityFields({
                workspaceId: context.activeWorkspace.id,
                playbookId,
              })}
              <PlaybookPendingButton
                idleLabel={editAction.label}
                pendingLabel="Creating draft…"
              />
            </form>
          )}
          {editAction?.kind === "continue" && (
            <Link className="button primary" href="#draft-editor-title">
              {editAction.label}
            </Link>
          )}
        </header>

        {currentPublished && (
          <p className="playbook-version-note">
            Published versions stay unchanged so previous call scores remain
            accurate. Editing creates a new draft version.
          </p>
        )}

        {(notice || actionError) && (
          <p
            id="playbook-action-message"
            className={`playbook-message ${actionError ? "error" : "success"}`}
            role={actionError ? "alert" : "status"}
          >
            {actionError ?? notice}
          </p>
        )}

        {draft && canEditPlaybookVersion(draft.status, context.role) && (
          <section
            aria-describedby={actionError ? "playbook-action-message" : undefined}
            aria-labelledby="draft-editor-title"
            className="draft-editor"
          >
            <div className="section-heading">
              <div>
                <p className="eyebrow">Editable draft</p>
                <h2 id="draft-editor-title">Edit playbook details</h2>
                <p className="draft-version-label">
                  Working draft · Version {draft.versionNumber}
                </p>
              </div>
              <span className="version-badge draft">Private draft</span>
            </div>

            <form action={updatePlaybookDraft} className="playbook-form metadata-form">
              {hiddenIdentityFields({
                workspaceId: context.activeWorkspace.id,
                playbookId,
                versionId: draft.id,
              })}
              <div>
                <label htmlFor="draft-playbook-name">Playbook name</label>
                <input
                  defaultValue={draft.name}
                  id="draft-playbook-name"
                  maxLength={PLAYBOOK_LIMITS.name}
                  name="name"
                  required
                />
              </div>
              <div>
                <label htmlFor="draft-playbook-vertical">Vertical</label>
                <select
                  defaultValue={draft.vertical}
                  id="draft-playbook-vertical"
                  name="vertical"
                >
                  <option value="sales">Sales</option>
                </select>
              </div>
              <PlaybookPendingButton
                className="button secondary small"
                idleLabel="Save details"
                pendingLabel="Saving…"
              />
            </form>

            <LivePlaybookWeights
              initialTotal={totalCriterionWeight(draft.criteria) ?? 0}
            >
              <div className="criteria-heading">
                <div>
                  <p className="eyebrow">Ordered scoring criteria</p>
                  <h2>{draft.criteria.length} of {PLAYBOOK_LIMITS.criteria} criteria</h2>
                </div>
                <p>Saved criteria stay compact. Open Edit when you need to make a change.</p>
              </div>

              <DraftCriteriaEditor
                criteria={draft.criteria}
                playbookId={playbookId}
                versionId={draft.id}
                workspaceId={context.activeWorkspace.id}
              />
            </LivePlaybookWeights>

            <PublishPlaybookControl
              action={publishPlaybookVersion}
              disabled={!publishValidation?.valid}
              playbookId={playbookId}
              validationMessage={publishMessage}
              versionId={draft.id}
              workspaceId={context.activeWorkspace.id}
            />
          </section>
        )}

        {!draft && currentPublished && (
          <CurrentPublishedDefinition version={currentPublished} />
        )}

        <PreviousVersionHistory versions={historicalVersions} />

        {!currentPublished && (!draft || !canManage) ? (
          <section className="playbook-empty">
            <h2>No published version is available.</h2>
            <p>An owner or admin must finish and publish the first draft.</p>
          </section>
        ) : null}
      </main>
    </div>
  );
}
