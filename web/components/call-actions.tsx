"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import {
  type FormEvent,
  type KeyboardEvent,
  useEffect,
  useRef,
  useState,
} from "react";

import { createClient } from "@/lib/supabase/client";

type RetryStage = "transcription" | "analysis" | null;
type WorkingAction = "rename" | "delete" | "retry" | null;
type OpenDialog = "rename" | "delete" | null;

type CallActionsProps = {
  callId: string;
  workspaceId: string;
  displayName: string;
  originalFilename: string;
  canManage: boolean;
  retryStage: RetryStage;
  isDeleting: boolean;
  viewHref?: string;
  afterDeleteHref?: string;
};

type DeletionPreparation = {
  outcome: "prepared" | "already_deleting" | "processing_active";
  storageBucket: string | null;
  storagePath: string | null;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseRenameResult(value: unknown, callId: string) {
  return (
    isRecord(value) &&
    value.call_id === callId &&
    typeof value.display_name === "string" &&
    value.display_name.length > 0 &&
    value.display_name.length <= 120
  );
}

function parseDeletionPreparation(
  value: unknown,
  workspaceId: string,
  callId: string,
): DeletionPreparation | null {
  if (!isRecord(value) || typeof value.outcome !== "string") return null;

  if (value.outcome === "processing_active") {
    if (value.storage_bucket !== null || value.storage_path !== null) return null;
    return {
      outcome: "processing_active",
      storageBucket: null,
      storagePath: null,
    };
  }

  if (
    (value.outcome !== "prepared" && value.outcome !== "already_deleting") ||
    value.storage_bucket !== "call-audio" ||
    typeof value.storage_path !== "string"
  ) {
    return null;
  }

  const expectedPrefix = `${workspaceId}/${callId}/source.`;
  const extension = value.storage_path.slice(expectedPrefix.length);
  if (
    !value.storage_path.startsWith(expectedPrefix) ||
    !["mp3", "mp4", "m4a", "wav", "webm", "ogg"].includes(extension)
  ) {
    return null;
  }

  return {
    outcome: value.outcome,
    storageBucket: value.storage_bucket,
    storagePath: value.storage_path,
  };
}

export function CallActions({
  callId,
  workspaceId,
  displayName,
  originalFilename,
  canManage,
  retryStage,
  isDeleting,
  viewHref,
  afterDeleteHref,
}: CallActionsProps) {
  const router = useRouter();
  const rootRef = useRef<HTMLDivElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const dialogRef = useRef<HTMLElement>(null);
  const renameInputRef = useRef<HTMLInputElement>(null);
  const deleteCancelRef = useRef<HTMLButtonElement>(null);
  const menuFocusTarget = useRef<"first" | "last" | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  const [dialog, setDialog] = useState<OpenDialog>(null);
  const [working, setWorking] = useState<WorkingAction>(null);
  const [message, setMessage] = useState<string | null>(null);
  const [messageTone, setMessageTone] = useState<"success" | "error">("success");

  useEffect(() => {
    if (!menuOpen) return;

    if (menuFocusTarget.current) {
      const items = Array.from(
        menuRef.current?.querySelectorAll<HTMLElement>("[role='menuitem']") ?? [],
      );
      const target = menuFocusTarget.current === "first" ? items[0] : items.at(-1);
      menuFocusTarget.current = null;
      target?.focus();
    }

    function handlePointerDown(event: PointerEvent) {
      if (!rootRef.current?.contains(event.target as Node)) setMenuOpen(false);
    }

    function handleEscape(event: globalThis.KeyboardEvent) {
      if (event.key === "Escape") {
        setMenuOpen(false);
        triggerRef.current?.focus();
      }
    }

    document.addEventListener("pointerdown", handlePointerDown);
    document.addEventListener("keydown", handleEscape);
    return () => {
      document.removeEventListener("pointerdown", handlePointerDown);
      document.removeEventListener("keydown", handleEscape);
    };
  }, [menuOpen]);

  useEffect(() => {
    if (!dialog) return;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    if (dialog === "rename") renameInputRef.current?.focus();
    if (dialog === "delete") deleteCancelRef.current?.focus();
    return () => {
      document.body.style.overflow = previousOverflow;
    };
  }, [dialog]);

  if (!canManage && !viewHref) return null;

  function openDialog(nextDialog: Exclude<OpenDialog, null>) {
    setMenuOpen(false);
    setMessage(null);
    setDialog(nextDialog);
  }

  function closeDialog() {
    if (working) return;
    setDialog(null);
    triggerRef.current?.focus();
  }

  function handleMenuKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    const items = Array.from(
      menuRef.current?.querySelectorAll<HTMLElement>("[role='menuitem']") ?? [],
    );
    if (items.length === 0) return;
    const activeIndex = items.indexOf(document.activeElement as HTMLElement);
    const step = event.key === "ArrowDown" ? 1 : -1;
    const nextIndex = activeIndex < 0
      ? event.key === "ArrowDown" ? 0 : items.length - 1
      : (activeIndex + step + items.length) % items.length;
    items[nextIndex]?.focus();
  }

  function handleTriggerKeyDown(event: KeyboardEvent<HTMLButtonElement>) {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    menuFocusTarget.current = event.key === "ArrowDown" ? "first" : "last";
    setMenuOpen(true);
  }

  async function handleRename(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (working) return;

    const formData = new FormData(event.currentTarget);
    const nextName = String(formData.get("displayName") ?? "").trim();
    if (!nextName || nextName.length > 120 || /[\u0000-\u001f\u007f]/.test(nextName)) {
      setMessageTone("error");
      setMessage("Enter a call name between 1 and 120 characters.");
      return;
    }

    setWorking("rename");
    setMessage(null);
    const supabase = createClient();
    const { data, error } = await supabase
      .rpc("rename_call", {
        p_workspace_id: workspaceId,
        p_call_id: callId,
        p_display_name: nextName,
      })
      .maybeSingle();

    if (error || !parseRenameResult(data, callId)) {
      setMessageTone("error");
      setMessage("The call could not be renamed. Please try again.");
      setWorking(null);
      return;
    }

    setWorking(null);
    setDialog(null);
    setMessageTone("success");
    setMessage("Call renamed.");
    triggerRef.current?.focus();
    router.refresh();
  }

  async function handleRetry() {
    if (working || !retryStage) return;
    setMenuOpen(false);
    triggerRef.current?.focus();
    setWorking("retry");
    setMessageTone("success");
    setMessage("Queuing processing...");

    const supabase = createClient();
    const { data, error } = await supabase.rpc("retry_failed_call_processing", {
      p_workspace_id: workspaceId,
      p_call_id: callId,
    });

    if (error || data !== retryStage) {
      setMessageTone("error");
      setMessage("Processing could not be queued. Refresh the page and try again.");
      setWorking(null);
      return;
    }

    setWorking(null);
    setMessageTone("success");
    setMessage(
      retryStage === "transcription"
        ? "Transcription queued."
        : "Analysis queued.",
    );
    router.refresh();
  }

  async function handleDelete() {
    if (working) return;
    setWorking("delete");
    setMessage(null);

    const supabase = createClient();
    const { data, error } = await supabase
      .rpc("prepare_call_deletion", {
        p_workspace_id: workspaceId,
        p_call_id: callId,
      })
      .maybeSingle();
    const preparation = parseDeletionPreparation(data, workspaceId, callId);

    if (error || !preparation) {
      setMessageTone("error");
      setMessage("Secure deletion could not be prepared. Please refresh and try again.");
      setWorking(null);
      return;
    }

    if (preparation.outcome === "processing_active") {
      setMessageTone("error");
      setMessage("Wait for processing to finish before deleting this call.");
      setWorking(null);
      return;
    }

    if (!preparation.storageBucket || !preparation.storagePath) {
      setMessageTone("error");
      setMessage("Secure deletion could not be prepared. Please refresh and try again.");
      setWorking(null);
      return;
    }

    const { error: storageError } = await supabase.storage
      .from(preparation.storageBucket)
      .remove([preparation.storagePath]);

    if (storageError) {
      setMessageTone("error");
      setMessage("The recording could not be removed. Retry deletion from this call.");
      setWorking(null);
      router.refresh();
      return;
    }

    const { data: finalizeResult, error: finalizeError } = await supabase.rpc(
      "finalize_call_deletion",
      {
        p_workspace_id: workspaceId,
        p_call_id: callId,
      },
    );

    if (finalizeError || finalizeResult !== "deleted") {
      setMessageTone("error");
      setMessage("The recording was removed, but deletion is not finished. Retry deletion.");
      setWorking(null);
      router.refresh();
      return;
    }

    setWorking(null);
    setDialog(null);
    if (afterDeleteHref) {
      router.push(afterDeleteHref);
    } else {
      router.refresh();
    }
  }

  function handleDialogKeyDown(event: KeyboardEvent<HTMLElement>) {
    if (event.key === "Escape" && !working) {
      event.preventDefault();
      closeDialog();
      return;
    }

    if (event.key === "Tab") {
      const focusable = Array.from(
        dialogRef.current?.querySelectorAll<HTMLElement>(
          "button:not(:disabled), input:not(:disabled), a[href]",
        ) ?? [],
      );
      if (focusable.length === 0) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last?.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first?.focus();
      }
    }
  }

  return (
    <div className="call-actions" ref={rootRef}>
      <button
        aria-busy={working === "retry"}
        aria-expanded={menuOpen}
        aria-haspopup="menu"
        aria-label={`Actions for ${displayName}`}
        className="actions-trigger"
        disabled={working === "retry"}
        onClick={() => setMenuOpen((open) => !open)}
        onKeyDown={handleTriggerKeyDown}
        ref={triggerRef}
        type="button"
      >
        <span aria-hidden="true">•••</span>
      </button>

      {menuOpen && (
        <div
          aria-label={`Actions for ${displayName}`}
          className="actions-menu"
          onKeyDown={handleMenuKeyDown}
          ref={menuRef}
          role="menu"
        >
          {viewHref && (
            <Link href={viewHref} onClick={() => setMenuOpen(false)} role="menuitem">
              View call
            </Link>
          )}
          {canManage && !isDeleting && (
            <button onClick={() => openDialog("rename")} role="menuitem" type="button">
              Rename
            </button>
          )}
          {canManage && retryStage && !isDeleting && (
            <button onClick={handleRetry} role="menuitem" type="button">
              Retry processing
            </button>
          )}
          {canManage && (
            <button
              className="danger-menu-item"
              onClick={() => openDialog("delete")}
              role="menuitem"
              type="button"
            >
              {isDeleting ? "Retry deletion" : "Delete"}
            </button>
          )}
        </div>
      )}

      {message && !dialog && (
        <p
          className={`action-message ${messageTone}`}
          role={messageTone === "error" ? "alert" : "status"}
        >
          {message}
        </p>
      )}

      {dialog === "rename" && (
        <div className="dialog-backdrop" onMouseDown={(event) => {
          if (event.target === event.currentTarget) closeDialog();
        }}>
          <section
            aria-labelledby={`rename-title-${callId}`}
            aria-modal="true"
            className="action-dialog"
            onKeyDown={handleDialogKeyDown}
            ref={dialogRef}
            role="dialog"
          >
            <p className="eyebrow">Call details</p>
            <h2 id={`rename-title-${callId}`}>Rename call</h2>
            <p className="muted">The original source filename will remain unchanged.</p>
            <form className="action-form" onSubmit={handleRename}>
              <label htmlFor={`display-name-${callId}`}>Call name</label>
              <input
                defaultValue={displayName}
                disabled={working === "rename"}
                id={`display-name-${callId}`}
                maxLength={120}
                name="displayName"
                ref={renameInputRef}
                required
              />
              {originalFilename !== displayName && (
                <p className="source-note">Source file: {originalFilename}</p>
              )}
              {message && (
                <p className={`dialog-message ${messageTone}`} role="alert">
                  {message}
                </p>
              )}
              <div className="dialog-actions">
                <button
                  className="button ghost"
                  disabled={working === "rename"}
                  onClick={closeDialog}
                  type="button"
                >
                  Cancel
                </button>
                <button
                  aria-busy={working === "rename"}
                  className="button primary"
                  disabled={working === "rename"}
                  type="submit"
                >
                  {working === "rename" ? "Saving..." : "Rename"}
                </button>
              </div>
            </form>
          </section>
        </div>
      )}

      {dialog === "delete" && (
        <div className="dialog-backdrop" onMouseDown={(event) => {
          if (event.target === event.currentTarget) closeDialog();
        }}>
          <section
            aria-describedby={`delete-description-${callId}`}
            aria-labelledby={`delete-title-${callId}`}
            aria-modal="true"
            className="action-dialog"
            onKeyDown={handleDialogKeyDown}
            ref={dialogRef}
            role="alertdialog"
          >
            <p className="eyebrow danger-eyebrow">Permanent action</p>
            <h2 id={`delete-title-${callId}`}>
              {isDeleting ? "Retry secure deletion?" : "Delete this call?"}
            </h2>
            <p className="muted" id={`delete-description-${callId}`}>
              This permanently removes the recording, transcript, and AI analysis.
              This action cannot be undone.
            </p>
            {message && (
              <p className={`dialog-message ${messageTone}`} role="alert">
                {message}
              </p>
            )}
            <div className="dialog-actions">
              <button
                className="button ghost"
                disabled={working === "delete"}
                onClick={closeDialog}
                ref={deleteCancelRef}
                type="button"
              >
                Cancel
              </button>
              <button
                aria-busy={working === "delete"}
                className="button danger"
                disabled={working === "delete"}
                onClick={handleDelete}
                type="button"
              >
                {working === "delete"
                  ? "Deleting..."
                  : isDeleting ? "Retry deletion" : "Delete call"}
              </button>
            </div>
          </section>
        </div>
      )}
    </div>
  );
}
