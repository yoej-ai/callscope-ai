import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

import {
  canManageScorecards,
  parseQueueScorecardResult,
  parseScorecardOutcome,
  scorecardOutcomeLabel,
  scorecardPresentation,
  scorecardScoreLabel,
} from "../lib/scorecards.mjs";

describe("custom scorecard presentation", () => {
  it("presents every lifecycle state without exposing internal errors", () => {
    assert.equal(
      scorecardPresentation({ status: "queued", configured: true, eligible: true, canManage: true }).label,
      "Waiting for AI scorecard",
    );
    assert.equal(
      scorecardPresentation({ status: "processing", configured: true, eligible: true, canManage: true }).kind,
      "processing",
    );
    assert.equal(
      scorecardPresentation({ status: "failed", configured: true, eligible: true, canManage: true }).label,
      "Scorecard unavailable",
    );
  });

  it("uses understandable outcome labels", () => {
    assert.equal(scorecardOutcomeLabel("pass"), "Pass");
    assert.equal(scorecardOutcomeLabel("fail"), "Needs improvement");
    assert.equal(scorecardOutcomeLabel("not_applicable"), "Not applicable");
    assert.equal(scorecardOutcomeLabel("insufficient_evidence"), "Review required");
    assert.equal(parseScorecardOutcome("invented"), null);
  });

  it("supports nullable deterministic scores and review UI", () => {
    assert.equal(scorecardScoreLabel(82.5), "82.50 / 100");
    assert.equal(scorecardScoreLabel(null), "Score unavailable");
  });

  it("limits configuration and manual queue actions to managers", () => {
    assert.equal(canManageScorecards("owner"), true);
    assert.equal(canManageScorecards("admin"), true);
    assert.equal(canManageScorecards("member"), false);
    assert.equal(
      scorecardPresentation({ status: null, configured: true, eligible: true, canManage: false }).kind,
      "unavailable",
    );
  });

  it("distinguishes missing configuration from an eligible call", () => {
    assert.equal(
      scorecardPresentation({ status: null, configured: false, eligible: true, canManage: true }).kind,
      "unconfigured",
    );
    assert.equal(
      scorecardPresentation({ status: null, configured: true, eligible: true, canManage: true }).kind,
      "eligible",
    );
  });

  it("strictly parses bounded queue results", () => {
    assert.deepEqual(
      parseQueueScorecardResult([
        {
          scorecard_id: "123e4567-e89b-42d3-a456-426614174000",
          status: "queued",
          created: true,
        },
      ]),
      {
        scorecardId: "123e4567-e89b-42d3-a456-426614174000",
        status: "queued",
        created: true,
      },
    );
    assert.equal(
      parseQueueScorecardResult([
        { scorecard_id: "scorecard-id", status: "ineligible", created: false },
      ]),
      null,
    );
  });

  it("keeps exact Playbook attribution and evidence deferral explicit in the UI", async () => {
    const [callDetail, playbooks] = await Promise.all([
      readFile(new URL("../app/dashboard/calls/[callId]/page.tsx", import.meta.url), "utf8"),
      readFile(new URL("../app/dashboard/playbooks/page.tsx", import.meta.url), "utf8"),
    ]);
    assert.match(callDetail, /Exact Version/);
    assert.match(callDetail, /Evidence and call snippets are intentionally not included/);
    assert.doesNotMatch(callDetail, /criterion\.evidence/);
    assert.match(playbooks, /Active scorecard Playbook/);
    assert.match(playbooks, /Existing scorecards always keep their original version/);
    assert.match(playbooks, /Use for AI scorecards/);
  });
});
