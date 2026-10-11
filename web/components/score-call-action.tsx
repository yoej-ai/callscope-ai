"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { parseQueueScorecardResult } from "@/lib/scorecards.mjs";
import { createClient } from "@/lib/supabase/client";

export function ScoreCallAction({
  callId,
  workspaceId,
}: {
  callId: string;
  workspaceId: string;
}) {
  const router = useRouter();
  const [pending, setPending] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  async function queueScorecard() {
    if (pending) return;
    setPending(true);
    setMessage(null);
    const supabase = createClient();
    const { data, error } = await supabase.rpc("queue_call_scorecard", {
      p_workspace_id: workspaceId,
      p_call_id: callId,
    });
    const result = parseQueueScorecardResult(data);
    if (error || !result) {
      setPending(false);
      setMessage("The scorecard could not be queued. Check the active Playbook and try again.");
      return;
    }
    setMessage(
      result.created
        ? "AI scorecard queued."
        : "This call already has an AI scorecard.",
    );
    setPending(false);
    router.refresh();
  }

  return (
    <div className="score-call-action">
      <button
        aria-busy={pending}
        className="button primary"
        disabled={pending}
        onClick={queueScorecard}
        type="button"
      >
        {pending ? "Queuing scorecard..." : "Score this call"}
      </button>
      {message && (
        <p role={message.startsWith("The scorecard") ? "alert" : "status"}>
          {message}
        </p>
      )}
    </div>
  );
}
