import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { isUuid } from "@/lib/api/types";
import {
  parseSpeakerAttributionStatus,
  parseSpeakerRole,
  type SpeakerAttributionStatus,
  type SpeakerRole,
} from "@/lib/speaker-turns.mjs";

export type TranscriptTurnDetail = {
  id: string;
  turnIndex: number;
  startMs: number;
  endMs: number;
  text: string;
  speakerKey: string;
  speakerRole: SpeakerRole;
};

export type SpeakerAttributionDetail = {
  status: SpeakerAttributionStatus;
  completedAt: string | null;
  turns: TranscriptTurnDetail[];
};

function isTimestamp(value: unknown): value is string {
  return typeof value === "string" && !Number.isNaN(Date.parse(value));
}

export async function loadSpeakerAttribution(
  supabase: SupabaseClient,
  callId: string,
): Promise<{ attribution: SpeakerAttributionDetail | null; error: boolean }> {
  const { data: row, error } = await supabase
    .from("call_speaker_attributions")
    .select("call_id, status, completed_at")
    .eq("call_id", callId)
    .maybeSingle();

  if (error) {
    console.error("Unable to load speaker attribution state", { code: error.code });
    return { attribution: null, error: true };
  }
  if (!row) return { attribution: null, error: false };

  const status = parseSpeakerAttributionStatus(row.status);
  if (
    row.call_id !== callId ||
    !status ||
    (row.completed_at !== null && !isTimestamp(row.completed_at)) ||
    (status === "completed") !== (row.completed_at !== null)
  ) {
    return { attribution: null, error: true };
  }

  if (status !== "completed") {
    return {
      attribution: { status, completedAt: null, turns: [] },
      error: false,
    };
  }

  const { data: turnRows, error: turnsError } = await supabase
    .from("call_transcript_turns")
    .select("id, call_id, turn_index, start_ms, end_ms, text, speaker_key, speaker_role")
    .eq("call_id", callId)
    .order("turn_index", { ascending: true })
    .limit(10_000);
  if (turnsError) {
    console.error("Unable to load completed speaker turns", { code: turnsError.code });
    return { attribution: null, error: true };
  }

  const turns: TranscriptTurnDetail[] = [];
  let totalCharacters = 0;
  for (const [index, turn] of (turnRows ?? []).entries()) {
    const role = parseSpeakerRole(turn.speaker_role);
    const validSpeakerKey =
      turn.speaker_key === "unknown" ||
      (typeof turn.speaker_key === "string" && /^speaker_[1-8]$/.test(turn.speaker_key));
    if (
      !isUuid(turn.id) ||
      turn.call_id !== callId ||
      turn.turn_index !== index ||
      typeof turn.start_ms !== "number" ||
      !Number.isSafeInteger(turn.start_ms) ||
      turn.start_ms < 0 ||
      typeof turn.end_ms !== "number" ||
      !Number.isSafeInteger(turn.end_ms) ||
      turn.end_ms < turn.start_ms ||
      turn.end_ms > 3_600_000 ||
      typeof turn.text !== "string" ||
      !turn.text.trim() ||
      turn.text.length > 5_000 ||
      !validSpeakerKey ||
      !role
    ) {
      return { attribution: null, error: true };
    }
    totalCharacters += turn.text.length;
    if (totalCharacters > 1_000_000) {
      return { attribution: null, error: true };
    }
    turns.push({
      id: turn.id,
      turnIndex: turn.turn_index,
      startMs: turn.start_ms,
      endMs: turn.end_ms,
      text: turn.text,
      speakerKey: turn.speaker_key,
      speakerRole: role,
    });
  }

  if (turns.length === 0) return { attribution: null, error: true };
  return {
    attribution: { status, completedAt: row.completed_at, turns },
    error: false,
  };
}
