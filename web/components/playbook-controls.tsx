"use client";

import { useState, type ReactNode } from "react";
import { useFormStatus } from "react-dom";
import { useRouter } from "next/navigation";

import {
  addPlaybookCriterion,
  movePlaybookCriterion,
  removePlaybookCriterion,
  updatePlaybookCriterion,
} from "@/app/dashboard/playbooks/actions";
import {
  criterionEditorTransition,
  disclosureChevronDirection,
  nextDisclosureState,
  pendingActionDisabled,
  PLAYBOOK_LIMITS,
  publishShellState,
  type PlaybookCriterion,
} from "@/lib/playbooks.mjs";

type PendingButtonProps = {
  idleLabel: string;
  pendingLabel: string;
  className?: string;
  disabled?: boolean;
  name?: string;
  value?: string;
};

export function PlaybookPendingButton({
  idleLabel,
  pendingLabel,
  className = "button primary",
  disabled = false,
  name,
  value,
}: PendingButtonProps) {
  const { pending } = useFormStatus();
  return (
    <button
      aria-busy={pending}
      className={className}
      disabled={pendingActionDisabled(disabled, pending)}
      name={name}
      type="submit"
      value={value}
    >
      {pending ? pendingLabel : idleLabel}
    </button>
  );
}

export function DisclosureChevron({ open }: { open: boolean }) {
  const direction = disclosureChevronDirection(open);
  return (
    <span
      aria-hidden="true"
      className="disclosure-chevron"
      data-direction={direction}
    >
      <svg fill="none" viewBox="0 0 16 16">
        <path
          d="m5.25 3.5 4.5 4.5-4.5 4.5"
          stroke="currentColor"
          strokeLinecap="round"
          strokeLinejoin="round"
          strokeWidth="1.75"
        />
      </svg>
    </span>
  );
}

export function LivePlaybookWeights({
  initialTotal,
  children,
}: {
  initialTotal: number;
  children: ReactNode;
}) {
  const ready = initialTotal === 100;
  return (
    <section className="playbook-criteria-workspace">
      <div className={`weight-summary ${ready ? "ready" : "needs-work"}`}>
        <div>
          <span>Saved criterion weight</span>
          <strong>{initialTotal}%</strong>
        </div>
        <p>
          {ready
            ? "Ready to publish after all saved fields pass validation."
            : `${Math.abs(100 - initialTotal)} percentage points ${initialTotal < 100 ? "remaining" : "over"}. Save changes before publishing.`}
        </p>
      </div>
      {children}
    </section>
  );
}

function HiddenIdentityFields({
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
}: {
  criterion?: PlaybookCriterion;
  idPrefix: string;
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

function CriterionCancelButton({ onCancel }: { onCancel: () => void }) {
  const { pending } = useFormStatus();
  return (
    <button
      className="button ghost small"
      disabled={pending}
      onClick={onCancel}
      type="button"
    >
      Cancel
    </button>
  );
}

type DraftCriteriaEditorProps = {
  criteria: PlaybookCriterion[];
  playbookId: string;
  versionId: string;
  workspaceId: string;
};

export function DraftCriteriaEditor({
  criteria,
  playbookId,
  versionId,
  workspaceId,
}: DraftCriteriaEditorProps) {
  const router = useRouter();
  const [editingCriterionId, setEditingCriterionId] = useState<string | null>(
    null,
  );
  const [addOpen, setAddOpen] = useState(false);
  const [actionFeedback, setActionFeedback] = useState<{
    message: string;
    tone: "error" | "success";
  } | null>(null);

  function beginEditing(criterionId: string) {
    setEditingCriterionId((current) =>
      criterionEditorTransition(current, "edit", criterionId),
    );
  }

  function cancelEditing(criterionId: string) {
    setEditingCriterionId((current) =>
      criterionEditorTransition(current, "cancel", criterionId),
    );
  }

  async function saveCriterion(criterionId: string, formData: FormData) {
    setActionFeedback(null);
    const result = await updatePlaybookCriterion(formData);
    if (!result.ok) {
      setEditingCriterionId((current) =>
        criterionEditorTransition(current, "save-failure", criterionId),
      );
      setActionFeedback({ message: result.message, tone: "error" });
      return;
    }
    setEditingCriterionId((current) =>
      criterionEditorTransition(current, "save-success", criterionId),
    );
    setActionFeedback({ message: result.message, tone: "success" });
    router.refresh();
  }

  async function addCriterion(formData: FormData) {
    setActionFeedback(null);
    const result = await addPlaybookCriterion(formData);
    if (!result.ok) {
      setAddOpen(true);
      setActionFeedback({ message: result.message, tone: "error" });
      return;
    }
    setAddOpen(false);
    setActionFeedback({ message: result.message, tone: "success" });
    router.refresh();
  }

  return (
    <>
      {actionFeedback && (
        <p
          className={`criterion-action-feedback ${actionFeedback.tone}`}
          role={actionFeedback.tone === "error" ? "alert" : "status"}
        >
          {actionFeedback.message}
        </p>
      )}
      {editingCriterionId && (
        <p className="criterion-edit-note" role="status">
          Finish or cancel the open edit before editing another criterion.
        </p>
      )}
      <div className="criterion-editor-list">
        {criteria.map((criterion, index) => {
          const editing = editingCriterionId === criterion.id;
          const identity = {
            workspaceId,
            playbookId,
            criterionId: criterion.id,
          };

          if (editing) {
            return (
              <article className="criterion-editor-card editing" key={criterion.id}>
                <header className="criterion-card-header">
                  <div className="criterion-heading-group">
                    <span className="criterion-position">{criterion.position}</span>
                    <div>
                      <p className="eyebrow">Editing criterion</p>
                      <h3>{criterion.name}</h3>
                    </div>
                  </div>
                </header>
                <form
                  action={(formData) => saveCriterion(criterion.id, formData)}
                  className="criterion-form"
                >
                  <HiddenIdentityFields {...identity} />
                  <CriterionFields
                    criterion={criterion}
                    idPrefix={`criterion-${criterion.id}`}
                  />
                  <div className="criterion-form-actions">
                    <CriterionCancelButton
                      onCancel={() => cancelEditing(criterion.id)}
                    />
                    <PlaybookPendingButton
                      className="button primary small criterion-save-button"
                      idleLabel="Save criterion"
                      pendingLabel="Saving…"
                    />
                  </div>
                </form>
              </article>
            );
          }

          return (
            <article className="criterion-editor-card saved" key={criterion.id}>
              <header className="criterion-card-header">
                <div className="criterion-heading-group">
                  <span className="criterion-position">{criterion.position}</span>
                  <div className="criterion-saved-content">
                    <div className="criterion-name-row">
                      <h3>{criterion.name}</h3>
                      <span className="criterion-saved-label">Saved</span>
                    </div>
                    <p>
                      {criterion.description ||
                        "No description provided. Open Edit to add context."}
                    </p>
                  </div>
                </div>
                <span
                  aria-label={`${criterion.weight} percent weight`}
                  className="criterion-weight"
                >
                  {criterion.weight}%
                </span>
              </header>
              <div className="criterion-card-actions">
                <button
                  className="button secondary small"
                  disabled={editingCriterionId !== null}
                  onClick={() => beginEditing(criterion.id)}
                  type="button"
                >
                  Edit
                </button>
                <div
                  aria-label={`Reorder ${criterion.name}`}
                  className="criterion-order-controls"
                  role="group"
                >
                  <form action={movePlaybookCriterion}>
                    <HiddenIdentityFields {...identity} />
                    <input name="direction" type="hidden" value="up" />
                    <PlaybookPendingButton
                      className="button ghost small"
                      disabled={index === 0 || editingCriterionId !== null}
                      idleLabel="Move up"
                      pendingLabel="Moving…"
                    />
                  </form>
                  <form action={movePlaybookCriterion}>
                    <HiddenIdentityFields {...identity} />
                    <input name="direction" type="hidden" value="down" />
                    <PlaybookPendingButton
                      className="button ghost small"
                      disabled={
                        index === criteria.length - 1 ||
                        editingCriterionId !== null
                      }
                      idleLabel="Move down"
                      pendingLabel="Moving…"
                    />
                  </form>
                </div>
                <form
                  action={removePlaybookCriterion}
                  className="criterion-remove-form"
                >
                  <HiddenIdentityFields {...identity} />
                  <PlaybookPendingButton
                    className="button ghost danger-text small"
                    disabled={editingCriterionId !== null}
                    idleLabel="Remove"
                    pendingLabel="Removing…"
                  />
                </form>
              </div>
            </article>
          );
        })}
      </div>

      {criteria.length < PLAYBOOK_LIMITS.criteria ? (
        <section className={`add-criterion-panel ${addOpen ? "open" : ""}`}>
          <button
            aria-controls="add-criterion-content"
            aria-expanded={addOpen}
            className="disclosure-trigger"
            onClick={() => setAddOpen((open) => nextDisclosureState(open))}
            type="button"
          >
            <DisclosureChevron open={addOpen} />
            <span>
              <strong>Add criterion</strong>
              <small>Create another scored behavior for this draft.</small>
            </span>
          </button>
          <div
            className="disclosure-content"
            hidden={!addOpen}
            id="add-criterion-content"
          >
            <form action={addCriterion} className="criterion-form">
              <HiddenIdentityFields
                playbookId={playbookId}
                versionId={versionId}
                workspaceId={workspaceId}
              />
              <CriterionFields idPrefix="new-criterion" />
              <PlaybookPendingButton
                className="button primary small"
                idleLabel="Add criterion"
                pendingLabel="Adding…"
              />
            </form>
          </div>
        </section>
      ) : (
        <p className="criterion-limit-note" role="status">
          This draft has reached the 20-criterion limit.
        </p>
      )}
    </>
  );
}

type PublishPlaybookControlProps = {
  action: (formData: FormData) => Promise<{ ok: boolean; message: string }>;
  workspaceId: string;
  playbookId: string;
  versionId: string;
  disabled: boolean;
  validationMessage: string;
};

function PublishShellContents({
  close,
  confirming,
  disabled,
  message,
  open,
  validationMessage,
  versionId,
}: {
  close: () => void;
  confirming: boolean;
  disabled: boolean;
  message: string | null;
  open: () => void;
  validationMessage: string;
  versionId: string;
}) {
  const { pending } = useFormStatus();
  const state = publishShellState(confirming, pending, disabled);
  const contentId = `publish-confirmation-${versionId}`;

  return (
    <section className={`publish-disclosure ${state.expanded ? "open" : ""}`}>
      <button
        aria-controls={contentId}
        aria-expanded={state.expanded}
        className="publish-disclosure-trigger"
        disabled={state.toggleDisabled || (!state.expanded && disabled)}
        onClick={state.expanded ? close : open}
        type="button"
      >
        <DisclosureChevron open={state.expanded} />
        <span>
          <strong>Publish this version</strong>
          <small>
            {disabled
              ? validationMessage
              : pending
                ? "Publishing is in progress. Keep this page open."
                : "Lock this draft and make it available for future evaluations."}
          </small>
        </span>
      </button>

      {state.contentVisible && (
        <div className="publish-confirmation" id={contentId}>
          <div>
            <strong>Publish this exact version?</strong>
            <p>
              Published versions stay unchanged so previous evaluations keep
              the exact scoring definition they used. Editing later creates a
              new draft.
            </p>
            {message && (
              <p className="publish-error" role="alert">
                {message}
              </p>
            )}
          </div>
          {state.actions && (
            <div className="publish-confirmation-actions">
              <button
                className="button ghost small"
                disabled={state.actions.keepEditing.disabled}
                onClick={close}
                type="button"
              >
                {state.actions.keepEditing.label}
              </button>
              <button
                aria-busy={state.actions.confirmPublish.busy}
                className="button primary small publish-confirm-button"
                disabled={state.actions.confirmPublish.disabled}
                type="submit"
              >
                {state.actions.confirmPublish.label}
              </button>
            </div>
          )}
        </div>
      )}
    </section>
  );
}

export function PublishPlaybookControl({
  action,
  workspaceId,
  playbookId,
  versionId,
  disabled,
  validationMessage,
}: PublishPlaybookControlProps) {
  const router = useRouter();
  const [confirming, setConfirming] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  async function submitPublish(formData: FormData) {
    setMessage(null);
    const result = await action(formData);
    if (!result.ok) {
      setConfirming(true);
      setMessage(result.message);
      return;
    }
    router.refresh();
  }

  return (
    <form action={submitPublish} className="publish-form-shell">
      <HiddenIdentityFields
        playbookId={playbookId}
        versionId={versionId}
        workspaceId={workspaceId}
      />
      <PublishShellContents
        close={() => {
          setMessage(null);
          setConfirming(false);
        }}
        confirming={confirming}
        disabled={disabled}
        message={message}
        open={() => setConfirming((current) => nextDisclosureState(current))}
        validationMessage={validationMessage}
        versionId={versionId}
      />
    </form>
  );
}
