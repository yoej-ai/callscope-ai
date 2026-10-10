import Link from "next/link";
import { notFound } from "next/navigation";

import {
  addPlaybookCriterion,
  createNextPlaybookVersion,
  movePlaybookCriterion,
  publishPlaybookVersion,
  removePlaybookCriterion,
  updatePlaybookCriterion,
  updatePlaybookDraft,
} from "@/app/dashboard/playbooks/actions";
import { DashboardNav } from "@/components/dashboard-nav";
import {
  LivePlaybookWeights,
  PlaybookPendingButton,
  PublishPlaybookControl,
} from "@/components/playbook-controls";
import {
  canManagePlaybooks,
  isPlaybookUuid,
  PLAYBOOK_LIMITS,
  playbookVersionLabel,
  totalCriterionWeight,
  validateCriteriaForPublish,
  type PlaybookCriterion,
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

function CriterionFields({
  criterion,
  idPrefix,
  liveWeight = false,
}: {
  criterion?: PlaybookCriterion;
  idPrefix: string;
  liveWeight?: boolean;
}) {
  return (
    <div className="criterion-fields">
      <div className="criterion-primary-fields">
        <div>
          <label htmlFor={`${idPrefix}-name`}>Criterion name</label>
          <input
            defaultValue={criterion?.name}
            id={`${idPrefix}-name`}
            maxLength={PLAYBOOK_LIMITS.criterionName}
            name="name"
            placeholder="Discovery"
            required
          />
        </div>
        <div>
          <label htmlFor={`${idPrefix}-weight`}>Weight</label>
          <div className="weight-input">
            <input
              data-playbook-weight={liveWeight ? "true" : undefined}
              defaultValue={criterion?.weight ?? 10}
              id={`${idPrefix}-weight`}
              inputMode="numeric"
              max={100}
              min={1}
              name="weight"
              required
              type="number"
            />
            <span aria-hidden="true">%</span>
          </div>
        </div>
      </div>
      <div>
        <label htmlFor={`${idPrefix}-description`}>Description</label>
        <textarea
          defaultValue={criterion?.description}
          id={`${idPrefix}-description`}
          maxLength={PLAYBOOK_LIMITS.description}
          name="description"
          placeholder="What this criterion measures and why it matters."
          rows={3}
        />
      </div>
      <div className="guidance-grid">
        <div>
          <label htmlFor={`${idPrefix}-pass`}>Pass evidence and guidance</label>
          <textarea
            defaultValue={criterion?.passGuidance}
            id={`${idPrefix}-pass`}
            maxLength={PLAYBOOK_LIMITS.guidance}
            name="passGuidance"
            placeholder="What strong evidence sounds like."
            rows={4}
          />
        </div>
        <div>
          <label htmlFor={`${idPrefix}-fail`}>Fail evidence and guidance</label>
          <textarea
            defaultValue={criterion?.failGuidance}
            id={`${idPrefix}-fail`}
            maxLength={PLAYBOOK_LIMITS.guidance}
            name="failGuidance"
            placeholder="What missing or weak evidence looks like."
            rows={4}
          />
        </div>
      </div>
    </div>
  );
}

function DraftCriterion({
  criterion,
  index,
  count,
  workspaceId,
  playbookId,
}: {
  criterion: PlaybookCriterion;
  index: number;
  count: number;
  workspaceId: string;
  playbookId: string;
}) {
  const identity = { workspaceId, playbookId, criterionId: criterion.id };
  return (
    <article className="criterion-editor-card">
      <header>
        <div>
          <span className="criterion-position">{criterion.position}</span>
          <div>
            <p className="eyebrow">Scoring criterion</p>
            <h3>{criterion.name}</h3>
          </div>
        </div>
        <div className="criterion-order-controls" aria-label={`Reorder ${criterion.name}`}>
          <form action={movePlaybookCriterion}>
            {hiddenIdentityFields(identity)}
            <input name="direction" type="hidden" value="up" />
            <PlaybookPendingButton
              className="button ghost small"
              disabled={index === 0}
              idleLabel="Move up"
              pendingLabel="Moving…"
            />
          </form>
          <form action={movePlaybookCriterion}>
            {hiddenIdentityFields(identity)}
            <input name="direction" type="hidden" value="down" />
            <PlaybookPendingButton
              className="button ghost small"
              disabled={index === count - 1}
              idleLabel="Move down"
              pendingLabel="Moving…"
            />
          </form>
        </div>
      </header>
      <form action={updatePlaybookCriterion} className="criterion-form">
        {hiddenIdentityFields(identity)}
        <CriterionFields
          criterion={criterion}
          idPrefix={`criterion-${criterion.id}`}
          liveWeight
        />
        <div className="criterion-form-actions">
          <PlaybookPendingButton
            className="button secondary small"
            idleLabel="Save criterion"
            pendingLabel="Saving…"
          />
        </div>
      </form>
      <form action={removePlaybookCriterion} className="criterion-remove-form">
        {hiddenIdentityFields(identity)}
        <PlaybookPendingButton
          className="button ghost small"
          idleLabel="Remove criterion"
          pendingLabel="Removing…"
        />
      </form>
    </article>
  );
}

function PublishedVersion({ version }: { version: PlaybookVersion }) {
  return (
    <article className="published-version-card">
      <header>
        <div>
          <span className="version-badge published">Published</span>
          <h2>{version.name}</h2>
          <p>
            {playbookVersionLabel(version.versionNumber, version.status)} · {" "}
            {humanizeDisplayLabel(version.vertical)}
          </p>
        </div>
        <div className="published-lock">
          <span aria-hidden="true">✓</span>
          Immutable
        </div>
      </header>
      <p className="published-date">
        Published {version.publishedAt ? formatDate(version.publishedAt) : ""}
      </p>
      <ol className="published-criteria-list">
        {version.criteria.map((criterion) => (
          <li key={criterion.id}>
            <div className="published-criterion-heading">
              <strong>{criterion.name}</strong>
              <span>{criterion.weight}%</span>
            </div>
            {criterion.description && <p>{criterion.description}</p>}
            <div className="published-guidance-grid">
              <div>
                <span>Pass guidance</span>
                <p>{criterion.passGuidance || "No guidance provided."}</p>
              </div>
              <div>
                <span>Fail guidance</span>
                <p>{criterion.failGuidance || "No guidance provided."}</p>
              </div>
            </div>
          </li>
        ))}
      </ol>
    </article>
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
  const published = playbook.versions
    .filter((version) => version.status === "published")
    .sort((left, right) => right.versionNumber - left.versionNumber);
  const latest = playbook.versions.at(-1);
  if (!latest) notFound();

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
              <span className={`version-badge ${latest.status}`}>
                {latest.status === "draft" ? "Draft" : "Published"}
              </span>
              <span>{playbookVersionLabel(latest.versionNumber, latest.status)}</span>
            </div>
            <h1>{latest.name}</h1>
            <p className="lede">
              {humanizeDisplayLabel(latest.vertical)} playbook · {context.activeWorkspace.name}
            </p>
          </div>
          {canManage && !draft && published.length > 0 && (
            <form action={createNextPlaybookVersion}>
              {hiddenIdentityFields({
                workspaceId: context.activeWorkspace.id,
                playbookId,
              })}
              <PlaybookPendingButton
                idleLabel="Create new version"
                pendingLabel="Creating version…"
              />
            </form>
          )}
        </header>

        {(notice || actionError) && (
          <p
            className={`playbook-message ${actionError ? "error" : "success"}`}
            role={actionError ? "alert" : "status"}
          >
            {actionError ?? notice}
          </p>
        )}

        {draft && canManage && (
          <section className="draft-editor" aria-labelledby="draft-editor-title">
            <div className="section-heading">
              <div>
                <p className="eyebrow">Editable draft</p>
                <h2 id="draft-editor-title">
                  Configure Version {draft.versionNumber}
                </h2>
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
                <p>Use Move Up and Move Down to set evaluation order.</p>
              </div>

              <div className="criterion-editor-list">
                {draft.criteria.map((criterion, index) => (
                  <DraftCriterion
                    count={draft.criteria.length}
                    criterion={criterion}
                    index={index}
                    key={criterion.id}
                    playbookId={playbookId}
                    workspaceId={context.activeWorkspace.id}
                  />
                ))}
              </div>

              {draft.criteria.length < PLAYBOOK_LIMITS.criteria ? (
                <details className="add-criterion-panel">
                  <summary>Add criterion</summary>
                  <form action={addPlaybookCriterion} className="criterion-form">
                    {hiddenIdentityFields({
                      workspaceId: context.activeWorkspace.id,
                      playbookId,
                      versionId: draft.id,
                    })}
                    <CriterionFields idPrefix="new-criterion" />
                    <PlaybookPendingButton
                      idleLabel="Add criterion"
                      pendingLabel="Adding…"
                    />
                  </form>
                </details>
              ) : (
                <p className="criterion-limit-note" role="status">
                  This draft has reached the 20-criterion limit.
                </p>
              )}
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

        {published.length > 0 ? (
          <section className="published-history" aria-labelledby="published-history-title">
            <div className="section-heading">
              <div>
                <p className="eyebrow">Permanent history</p>
                <h2 id="published-history-title">Published versions</h2>
              </div>
              <p>Each version remains stable for future score attribution.</p>
            </div>
            <div className="published-version-list">
              {published.map((version) => (
                <PublishedVersion key={version.id} version={version} />
              ))}
            </div>
          </section>
        ) : !draft || !canManage ? (
          <section className="playbook-empty">
            <h2>No published version is available.</h2>
            <p>An owner or admin must finish and publish the first draft.</p>
          </section>
        ) : null}
      </main>
    </div>
  );
}
