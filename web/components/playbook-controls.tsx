"use client";

import type { ReactNode } from "react";
import { useFormStatus } from "react-dom";
import { useState } from "react";

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
      disabled={disabled || pending}
      name={name}
      type="submit"
      value={value}
    >
      {pending ? pendingLabel : idleLabel}
    </button>
  );
}

export function LivePlaybookWeights({
  initialTotal,
  children,
}: {
  initialTotal: number;
  children: ReactNode;
}) {
  const [total, setTotal] = useState(initialTotal);
  const [validInputs, setValidInputs] = useState(true);

  function updateTotal(container: HTMLElement) {
    const inputs = Array.from(
      container.querySelectorAll<HTMLInputElement>(
        "input[data-playbook-weight='true']",
      ),
    );
    let nextTotal = 0;
    let valid = true;
    for (const input of inputs) {
      const weight = Number(input.value);
      if (!Number.isSafeInteger(weight) || weight < 1 || weight > 100) {
        valid = false;
      } else {
        nextTotal += weight;
      }
    }
    setTotal(nextTotal);
    setValidInputs(valid);
  }

  const ready = validInputs && total === 100;
  return (
    <section
      className="playbook-criteria-workspace"
      onInput={(event) => updateTotal(event.currentTarget)}
    >
      <div className={`weight-summary ${ready ? "ready" : "needs-work"}`}>
        <div>
          <span>Total criterion weight</span>
          <strong aria-live="polite">
            {validInputs ? `${total}%` : "Check weights"}
          </strong>
        </div>
        <p>
          {ready
            ? "Ready for publishing after all saved fields pass validation."
            : validInputs
              ? `${Math.abs(100 - total)} percentage points ${total < 100 ? "remaining" : "over"}. Save changes before publishing.`
              : "Every saved weight must be a whole number from 1 to 100."}
        </p>
      </div>
      {children}
    </section>
  );
}

type PublishPlaybookControlProps = {
  action: (formData: FormData) => Promise<void>;
  workspaceId: string;
  playbookId: string;
  versionId: string;
  disabled: boolean;
  validationMessage: string;
};

export function PublishPlaybookControl({
  action,
  workspaceId,
  playbookId,
  versionId,
  disabled,
  validationMessage,
}: PublishPlaybookControlProps) {
  const [confirming, setConfirming] = useState(false);

  if (disabled) {
    return (
      <div className="publish-panel" aria-live="polite">
        <button className="button primary" disabled type="button">
          Publish version
        </button>
        <p>{validationMessage}</p>
      </div>
    );
  }

  if (!confirming) {
    return (
      <div className="publish-panel">
        <button
          className="button primary"
          onClick={() => setConfirming(true)}
          type="button"
        >
          Publish version
        </button>
        <p>Publishing locks this version and all of its criteria permanently.</p>
      </div>
    );
  }

  return (
    <div className="publish-confirmation" role="alert">
      <div>
        <strong>Publish this exact version?</strong>
        <p>
          Its metadata, order, guidance, and weights cannot be edited afterward.
        </p>
      </div>
      <div className="publish-confirmation-actions">
        <button
          className="button ghost small"
          onClick={() => setConfirming(false)}
          type="button"
        >
          Keep editing
        </button>
        <form action={action}>
          <input name="workspaceId" type="hidden" value={workspaceId} />
          <input name="playbookId" type="hidden" value={playbookId} />
          <input name="versionId" type="hidden" value={versionId} />
          <PlaybookPendingButton
            className="button primary small"
            idleLabel="Confirm publish"
            pendingLabel="Publishing…"
          />
        </form>
      </div>
    </div>
  );
}
