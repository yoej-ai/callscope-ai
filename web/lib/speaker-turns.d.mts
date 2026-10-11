export type SpeakerAttributionStatus = "queued" | "processing" | "completed" | "failed";
export type SpeakerRole = "agent" | "customer" | "unknown";

export function parseSpeakerAttributionStatus(
  value: unknown,
): SpeakerAttributionStatus | null;
export function parseSpeakerRole(value: unknown): SpeakerRole | null;
export function canManageSpeakerAttribution(role: unknown): boolean;
export function formatTranscriptTimestamp(milliseconds: unknown): string;
export function speakerDisplayLabel(role: unknown, speakerKey: unknown): string;
export function parseQueueSpeakerAttributionResult(value: unknown): {
  callId: string | null;
  status: SpeakerAttributionStatus | "ineligible";
  created: boolean;
} | null;
