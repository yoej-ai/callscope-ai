"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";

type PendingUploadRecoveryProps = {
  workspaceId: string;
  callId: string;
};

type StaleUploadReconciliationProps = {
  workspaceId: string;
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, expected: string[]) {
  const keys = Object.keys(value).sort();
  const sortedExpected = [...expected].sort();
  return (
    keys.length === sortedExpected.length &&
    keys.every((key, index) => key === sortedExpected[index])
  );
}

function isCompletedUpload(value: unknown, callId: string) {
  return (
    isRecord(value) &&
    hasExactKeys(value, ["call_id", "status"]) &&
    value.call_id === callId &&
    value.status === "uploaded"
  );
}

function parseReconciliationSummary(value: unknown) {
  if (
    !isRecord(value) ||
    !hasExactKeys(value, [
      "deleted",
      "failed",
      "processed",
      "results",
      "uploaded",
    ]) ||
    !Number.isSafeInteger(value.processed) ||
    !Number.isSafeInteger(value.uploaded) ||
    !Number.isSafeInteger(value.deleted) ||
    !Number.isSafeInteger(value.failed) ||
    (value.processed as number) < 0 ||
    (value.processed as number) > 20 ||
    (value.uploaded as number) < 0 ||
    (value.deleted as number) < 0 ||
    (value.failed as number) < 0 ||
    !Array.isArray(value.results) ||
    value.results.length !== value.processed ||
    (value.uploaded as number) +
      (value.deleted as number) +
      (value.failed as number) !==
      value.processed
  ) {
    return null;
  }

  const callIds = new Set<string>();
  let uploaded = 0;
  let deleted = 0;
  let failed = 0;
  for (const result of value.results) {
    if (
      !isRecord(result) ||
      !hasExactKeys(result, ["call_id", "outcome"]) ||
      typeof result.call_id !== "string" ||
      !UUID_PATTERN.test(result.call_id) ||
      !["deleted", "uploaded", "failed"].includes(
        typeof result.outcome === "string" ? result.outcome : "",
      ) ||
      callIds.has(result.call_id)
    ) {
      return null;
    }
    callIds.add(result.call_id);
    if (result.outcome === "uploaded") uploaded += 1;
    if (result.outcome === "deleted") deleted += 1;
    if (result.outcome === "failed") failed += 1;
  }

  if (
    value.uploaded !== uploaded ||
    value.deleted !== deleted ||
    value.failed !== failed
  ) {
    return null;
  }

  return {
    processed: value.processed as number,
    uploaded,
    deleted,
    failed,
  };
}

function recoveryError(status: number) {
  if (status === 401) {
    return "Your session has expired. Sign in again before retrying.";
  }
  if (status === 404) {
    return "This upload is not available or is not ready to verify.";
  }
  return "Upload verification is temporarily unavailable.";
}

export function PendingUploadRecovery({
  workspaceId,
  callId,
}: PendingUploadRecoveryProps) {
  const router = useRouter();
  const working = useRef(false);
  const [message, setMessage] = useState("");
  const [isWorking, setIsWorking] = useState(false);

  async function retryVerification() {
    if (working.current) return;
    working.current = true;
    setIsWorking(true);
    setMessage("Checking the stored recording…");

    try {
      const response = await fetch(
        `/api/workspaces/${encodeURIComponent(workspaceId)}/calls/${encodeURIComponent(callId)}/complete`,
        {
          method: "POST",
          cache: "no-store",
          headers: { "Content-Type": "application/json" },
          body: "{}",
        },
      );
      if (!response.ok) {
        setMessage(recoveryError(response.status));
        return;
      }

      const completion: unknown = await response.json();
      if (!isCompletedUpload(completion, callId)) {
        setMessage("Upload verification returned an invalid response.");
        return;
      }

      setMessage("Upload verified.");
      router.refresh();
    } catch {
      setMessage("Upload verification is temporarily unavailable.");
    } finally {
      working.current = false;
      setIsWorking(false);
    }
  }

  return (
    <div className="recovery-action">
      <button
        aria-busy={isWorking}
        className="button ghost recovery-button"
        disabled={isWorking}
        onClick={retryVerification}
        type="button"
      >
        {isWorking ? "Checking…" : "Retry verification"}
      </button>
      <span aria-live="polite" className="recovery-message" role="status">
        {message}
      </span>
    </div>
  );
}

export function StaleUploadReconciliation({
  workspaceId,
}: StaleUploadReconciliationProps) {
  const router = useRouter();
  const working = useRef(false);
  const [message, setMessage] = useState("");
  const [isWorking, setIsWorking] = useState(false);

  async function reconcileStaleUploads() {
    if (working.current) return;
    working.current = true;
    setIsWorking(true);
    setMessage("Checking older pending uploads…");

    try {
      const response = await fetch(
        `/api/workspaces/${encodeURIComponent(workspaceId)}/calls/uploads/reconcile`,
        {
          method: "POST",
          cache: "no-store",
          headers: { "Content-Type": "application/json" },
          body: "{}",
        },
      );
      if (!response.ok) {
        setMessage(recoveryError(response.status));
        return;
      }

      const result = parseReconciliationSummary(await response.json());
      if (!result) {
        setMessage("Upload recovery returned an invalid response.");
        return;
      }

      setMessage(
        result.processed === 0
          ? "No stale uploads needed recovery."
          : `Recovered ${result.uploaded}, removed ${result.deleted}, and marked ${result.failed} failed.`,
      );
      router.refresh();
    } catch {
      setMessage("Upload recovery is temporarily unavailable.");
    } finally {
      working.current = false;
      setIsWorking(false);
    }
  }

  return (
    <div className="stale-recovery">
      <button
        aria-busy={isWorking}
        className="button ghost recovery-button"
        disabled={isWorking}
        onClick={reconcileStaleUploads}
        type="button"
      >
        {isWorking ? "Checking…" : "Check older uploads"}
      </button>
      <span aria-live="polite" className="recovery-message" role="status">
        {message}
      </span>
    </div>
  );
}
