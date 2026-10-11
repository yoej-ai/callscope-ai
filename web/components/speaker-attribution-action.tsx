"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { parseQueueSpeakerAttributionResult } from "@/lib/speaker-turns.mjs";
import { createClient } from "@/lib/supabase/client";

export function SpeakerAttributionAction({
  callId,
  workspaceId,
}: {
  callId: string;
  workspaceId: string;
}) {
  const router = useRouter();
  const [pending, setPending] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  async function queueSpeakerAttribution() {
    if (pending) return;
    setPending(true);
    setMessage(null);
    const supabase = createClient();
    const { data, error } = await supabase.rpc("queue_call_speaker_attribution", {
      p_workspace_id: workspaceId,
      p_call_id: callId,
    });
    const result = parseQueueSpeakerAttributionResult(data);
    if (error || !result || result.status === "ineligible") {
      setPending(false);
      setMessage("Speaker labels could not be queued. Check the recording and try again.");
      return;
    }
    setMessage(result.created ? "Speaker labels queued." : "Speaker labeling is already available or in progress.");
    setPending(false);
    router.refresh();
  }

  return (
    <div className="speaker-attribution-action">
      <button
        aria-busy={pending}
        className="button secondary compact"
        disabled={pending}
        onClick={queueSpeakerAttribution}
        type="button"
      >
        {pending ? "Queuing speaker labels..." : "Add speaker labels"}
      </button>
      {message && (
        <p role={message.startsWith("Speaker labels could") ? "alert" : "status"}>
          {message}
        </p>
      )}
    </div>
  );
}
