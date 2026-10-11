import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { isUuid } from "@/lib/api/types";
import {
  parseScorecardOutcome,
  parseScorecardStatus,
  type ScorecardOutcome,
  type ScorecardStatus,
} from "@/lib/scorecards.mjs";

export type ScorecardCriterionResult = {
  criterionId: string;
  name: string;
  weight: number;
  position: number;
  outcome: ScorecardOutcome;
};

export type CallScorecardDetail = {
  id: string;
  status: ScorecardStatus;
  playbookVersionId: string;
  playbookName: string;
  versionNumber: number;
  overallScore: number | null;
  reviewRequired: boolean;
  completedAt: string | null;
  criteria: ScorecardCriterionResult[];
};

function isTimestamp(value: unknown): value is string {
  return typeof value === "string" && !Number.isNaN(Date.parse(value));
}

export async function loadCallScorecard(
  supabase: SupabaseClient,
  workspaceId: string,
  callId: string,
): Promise<{
  configuredPlaybookId: string | null;
  scorecard: CallScorecardDetail | null;
  error: boolean;
}> {
  const [{ data: setting, error: settingError }, { data: row, error: rowError }] =
    await Promise.all([
      supabase
        .from("workspace_scorecard_settings")
        .select("playbook_id")
        .eq("workspace_id", workspaceId)
        .maybeSingle(),
      supabase
        .from("call_scorecards")
        .select(
          "id, playbook_version_id, status, overall_score, review_required, completed_at",
        )
        .eq("call_id", callId)
        .maybeSingle(),
    ]);

  if (settingError || rowError) {
    console.error("Unable to load call scorecard state", {
      code: settingError?.code ?? rowError?.code ?? "unknown",
    });
    return { configuredPlaybookId: null, scorecard: null, error: true };
  }

  const configuredPlaybookId = isUuid(setting?.playbook_id)
    ? setting.playbook_id
    : null;
  if (!row) return { configuredPlaybookId, scorecard: null, error: false };

  const status = parseScorecardStatus(row.status);
  if (
    !isUuid(row.id) ||
    !isUuid(row.playbook_version_id) ||
    !status ||
    typeof row.review_required !== "boolean" ||
    (row.overall_score !== null &&
      (typeof row.overall_score !== "number" ||
        !Number.isFinite(row.overall_score) ||
        row.overall_score < 0 ||
        row.overall_score > 100)) ||
    (row.completed_at !== null && !isTimestamp(row.completed_at))
  ) {
    return { configuredPlaybookId, scorecard: null, error: true };
  }

  const { data: version, error: versionError } = await supabase
    .from("playbook_versions")
    .select("id, playbook_id, version_number, status, name")
    .eq("id", row.playbook_version_id)
    .maybeSingle();
  if (
    versionError ||
    !version ||
    version.id !== row.playbook_version_id ||
    !isUuid(version.playbook_id) ||
    version.status !== "published" ||
    typeof version.name !== "string" ||
    !version.name.trim() ||
    typeof version.version_number !== "number" ||
    !Number.isSafeInteger(version.version_number) ||
    version.version_number < 1
  ) {
    return { configuredPlaybookId, scorecard: null, error: true };
  }

  const [playbookResponse, criteriaResponse, resultsResponse] = await Promise.all([
    supabase
      .from("playbooks")
      .select("id, workspace_id")
      .eq("id", version.playbook_id)
      .eq("workspace_id", workspaceId)
      .maybeSingle(),
    supabase
      .from("playbook_criteria")
      .select("id, name, weight, position")
      .eq("playbook_version_id", version.id)
      .order("position", { ascending: true })
      .limit(20),
    supabase
      .from("call_scorecard_results")
      .select("criterion_id, outcome")
      .eq("scorecard_id", row.id)
      .limit(20),
  ]);
  if (
    playbookResponse.error ||
    !playbookResponse.data ||
    criteriaResponse.error ||
    resultsResponse.error
  ) {
    return { configuredPlaybookId, scorecard: null, error: true };
  }

  const resultByCriterion = new Map<string, ScorecardOutcome>();
  for (const result of resultsResponse.data ?? []) {
    const outcome = parseScorecardOutcome(result.outcome);
    if (!isUuid(result.criterion_id) || !outcome || resultByCriterion.has(result.criterion_id)) {
      return { configuredPlaybookId, scorecard: null, error: true };
    }
    resultByCriterion.set(result.criterion_id, outcome);
  }

  const criteria: ScorecardCriterionResult[] = [];
  for (const criterion of criteriaResponse.data ?? []) {
    const outcome = resultByCriterion.get(criterion.id);
    if (
      !isUuid(criterion.id) ||
      typeof criterion.name !== "string" ||
      !criterion.name.trim() ||
      typeof criterion.weight !== "number" ||
      !Number.isSafeInteger(criterion.weight) ||
      typeof criterion.position !== "number" ||
      !Number.isSafeInteger(criterion.position) ||
      (status === "completed" && !outcome)
    ) {
      return { configuredPlaybookId, scorecard: null, error: true };
    }
    if (outcome) {
      criteria.push({
        criterionId: criterion.id,
        name: criterion.name,
        weight: criterion.weight,
        position: criterion.position,
        outcome,
      });
    }
  }
  if (
    status === "completed" &&
    (criteria.length === 0 || criteria.length !== resultByCriterion.size)
  ) {
    return { configuredPlaybookId, scorecard: null, error: true };
  }

  return {
    configuredPlaybookId,
    error: false,
    scorecard: {
      id: row.id,
      status,
      playbookVersionId: row.playbook_version_id,
      playbookName: version.name,
      versionNumber: version.version_number,
      overallScore: row.overall_score,
      reviewRequired: row.review_required,
      completedAt: row.completed_at,
      criteria,
    },
  };
}
