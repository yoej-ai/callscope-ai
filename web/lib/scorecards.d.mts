export type ScorecardStatus = "queued" | "processing" | "completed" | "failed";
export type ScorecardOutcome =
  | "pass"
  | "fail"
  | "not_applicable"
  | "insufficient_evidence";

export function parseScorecardStatus(value: unknown): ScorecardStatus | null;
export function parseScorecardOutcome(value: unknown): ScorecardOutcome | null;
export function scorecardOutcomeLabel(outcome: unknown): string;
export function canManageScorecards(role: unknown): boolean;
export function scorecardScoreLabel(score: number | null): string;
export function scorecardPresentation(value: {
  status: unknown;
  configured: boolean;
  eligible: boolean;
  canManage: boolean;
}): {
  kind:
    | ScorecardStatus
    | "unconfigured"
    | "eligible"
    | "unavailable";
  label: string;
};
export function parseQueueScorecardResult(value: unknown): {
  scorecardId: string;
  status: "queued" | "existing";
  created: boolean;
} | null;
