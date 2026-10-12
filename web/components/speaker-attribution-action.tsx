"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import {
  parseQueueSpeakerAttributionResult,
  parseRetrySpeakerAttributionResult,
} from "@/lib/speaker-turns.mjs";
import { createClient } from "@/lib/supabase/client";

export function SpeakerAttributionAction({
  callId,
  mode,
  workspaceId,
}: {
  callId: string;
  mode: "generate" | "retry";
  workspaceId: string;
}) {
  const router = useRouter();
  const [pending, setPending] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  async function submitSpeakerAttribution() {
    if (pending) return;
    setPending(true);
    setMessage(null);
    const supabase = createClient();
    const { data, error } = mode === "retry"
      ? await supabase.rpc("retry_call_speaker_attribution", {
          p_workspace_id: workspaceId,
          p_call_id: callId,
        })
      : await supabase.rpc("queue_call_speaker_attribution", {
          p_workspace_id: workspaceId,
          p_call_id: callId,
        });
    const result = mode === "retry"
      ? parseRetrySpeakerAttributionResult(data)
      : parseQueueSpeakerAttributionResult(data);
    if (
      error ||
      !result ||
      ("status" in result && result.status === "ineligible")
    ) {
      setPending(false);
      setMessage(
        mode === "retry"
          ? "Speaker detection could not be retried. Try again when processing is available."
          : "Speaker labels could not be queued. Check the recording and try again.",
      );
      return;
    }
    setMessage(
      mode === "retry"
        ? "Speaker detection queued again."
        : "created" in result && result.created
          ? "Speaker labels queued."
          : "Speaker labeling is already available or in progress.",
    );
    setPending(false);
    router.refresh();
  }

  return (
    <div className="speaker-attribution-action">
      <button
        aria-busy={pending}
        className="button secondary compact"
        disabled={pending}
        onClick={submitSpeakerAttribution}
        type="button"
      >
        {pending
          ? mode === "retry"
            ? "Retrying speaker detection..."
            : "Queuing speaker labels..."
          : mode === "retry"
            ? "Retry speaker detection"
            : "Generate speaker labels"}
      </button>
      {mode === "generate" && (
        <p>
          New calls are labeled automatically. Use this for older calls or if
          automatic speaker detection was not queued.
        </p>
      )}
      {message && (
        <p role={message.includes("could not") ? "alert" : "status"}>
          {message}
        </p>
      )}
    </div>
  );
}
