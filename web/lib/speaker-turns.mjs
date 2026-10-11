const STATUSES = new Set(["queued", "processing", "completed", "failed"]);
const ROLES = new Set(["agent", "customer", "unknown"]);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SPEAKER_KEY_RE = /^speaker_([1-8])$/;

/** @param {unknown} value */
export function parseSpeakerAttributionStatus(value) {
  return typeof value === "string" && STATUSES.has(value) ? value : null;
}

/** @param {unknown} value */
export function parseSpeakerRole(value) {
  return typeof value === "string" && ROLES.has(value) ? value : null;
}

/** @param {unknown} role */
export function canManageSpeakerAttribution(role) {
  return role === "owner" || role === "admin";
}

/** @param {unknown} milliseconds */
export function formatTranscriptTimestamp(milliseconds) {
  if (
    typeof milliseconds !== "number" ||
    !Number.isSafeInteger(milliseconds) ||
    milliseconds < 0 ||
    milliseconds > 604_800_000
  ) {
    return "--:--";
  }
  const totalSeconds = Math.floor(milliseconds / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`
    : `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
}

/** @param {unknown} role @param {unknown} speakerKey */
export function speakerDisplayLabel(role, speakerKey) {
  if (role === "agent") return "Agent";
  if (role === "customer") return "Customer";
  const match = typeof speakerKey === "string" ? SPEAKER_KEY_RE.exec(speakerKey) : null;
  return match ? `Speaker ${match[1]}` : "Speaker";
}

/** @param {unknown} value */
export function parseQueueSpeakerAttributionResult(value) {
  if (!Array.isArray(value) || value.length !== 1) return null;
  const row = value[0];
  if (!row || typeof row !== "object" || Array.isArray(row)) return null;
  if (
    Object.keys(row).sort().join(",") !== "call_id,created,status" ||
    (row.call_id !== null &&
      (typeof row.call_id !== "string" || !UUID_RE.test(row.call_id))) ||
    !["queued", "processing", "completed", "failed", "ineligible"].includes(row.status) ||
    typeof row.created !== "boolean"
  ) {
    return null;
  }
  if ((row.status === "ineligible") !== (row.call_id === null)) return null;
  return {
    callId: row.call_id,
    status: row.status,
    created: row.created,
  };
}
