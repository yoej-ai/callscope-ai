const STATUSES = new Set(["queued", "processing", "completed", "failed"]);
const OUTCOMES = new Set([
  "pass",
  "fail",
  "not_applicable",
  "insufficient_evidence",
]);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** @param {unknown} value */
export function parseScorecardStatus(value) {
  return typeof value === "string" && STATUSES.has(value) ? value : null;
}

/** @param {unknown} value */
export function parseScorecardOutcome(value) {
  return typeof value === "string" && OUTCOMES.has(value) ? value : null;
}

/** @param {unknown} outcome */
export function scorecardOutcomeLabel(outcome) {
  return {
    pass: "Pass",
    fail: "Needs improvement",
    not_applicable: "Not applicable",
    insufficient_evidence: "Review required",
  }[outcome] ?? "Unavailable";
}

/** @param {unknown} role */
export function canManageScorecards(role) {
  return role === "owner" || role === "admin";
}

/** @param {number | null} score */
export function scorecardScoreLabel(score) {
  return typeof score === "number" && Number.isFinite(score) && score >= 0 && score <= 100
    ? `${score.toFixed(2)} / 100`
    : "Score unavailable";
}

/**
 * @param {{status: unknown, configured: boolean, eligible: boolean, canManage: boolean}} value
 */
export function scorecardPresentation(value) {
  const status = parseScorecardStatus(value?.status);
  if (status === "queued") return { kind: "queued", label: "Waiting for AI scorecard" };
  if (status === "processing") return { kind: "processing", label: "Scoring in progress" };
  if (status === "failed") return { kind: "failed", label: "Scorecard unavailable" };
  if (status === "completed") return { kind: "completed", label: "AI Scorecard" };
  if (!value?.configured) {
    return { kind: "unconfigured", label: "Choose a published Playbook before scoring calls." };
  }
  if (value?.eligible && value?.canManage) {
    return { kind: "eligible", label: "Score this call" };
  }
  return { kind: "unavailable", label: "This call is not ready for scoring." };
}

/** @param {unknown} value */
export function parseQueueScorecardResult(value) {
  if (!Array.isArray(value) || value.length !== 1) return null;
  const row = value[0];
  if (!row || typeof row !== "object" || Array.isArray(row)) return null;
  if (
    typeof row.scorecard_id !== "string" ||
    !UUID_RE.test(row.scorecard_id) ||
    !["queued", "existing"].includes(row.status) ||
    typeof row.created !== "boolean"
  ) {
    return null;
  }
  return {
    scorecardId: row.scorecard_id,
    status: row.status,
    created: row.created,
  };
}
