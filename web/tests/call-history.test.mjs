import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  callHistoryPageCount,
  callHistoryStageLabel,
  dashboardCallHistoryHref,
  isActiveCallHistoryStage,
  normalizeCallSearch,
  parseCallHistoryPage,
  parseCallHistoryResponse,
  parseCallHistorySort,
  parseCallHistoryStatus,
} from "../lib/call-history.mjs";

describe("call history discovery helpers", () => {
  it("normalizes safe search text and rejects unsafe lengths or controls", () => {
    assert.deepEqual(normalizeCallSearch("  Discovery call  "), {
      value: "Discovery call",
      error: null,
    });
    assert.deepEqual(normalizeCallSearch("   "), { value: "", error: null });
    assert.equal(normalizeCallSearch("bad\nquery").value, "");
    assert.match(normalizeCallSearch("x".repeat(101)).error, /100 characters/);
  });

  it("whitelists status and sort URL values", () => {
    assert.equal(parseCallHistoryStatus("in_progress"), "in_progress");
    assert.equal(parseCallHistoryStatus("completed"), "completed");
    assert.equal(parseCallHistoryStatus("anything"), "all");
    assert.equal(parseCallHistorySort("oldest"), "oldest");
    assert.equal(parseCallHistorySort("created_at desc"), "newest");
  });

  it("accepts only bounded positive integer pages", () => {
    assert.equal(parseCallHistoryPage("2"), 2);
    assert.equal(parseCallHistoryPage("0"), 1);
    assert.equal(parseCallHistoryPage("-4"), 1);
    assert.equal(parseCallHistoryPage("1.5"), 1);
    assert.equal(parseCallHistoryPage("10001"), 1);
  });

  it("provides lifecycle labels and active-stage detection", () => {
    assert.equal(callHistoryStageLabel("waiting_transcription"), "Waiting for transcription");
    assert.equal(callHistoryStageLabel("waiting_analysis"), "Waiting for AI analysis");
    assert.equal(callHistoryStageLabel("deleting"), "Deletion in progress");
    assert.equal(isActiveCallHistoryStage("analyzing"), true);
    assert.equal(isActiveCallHistoryStage("completed"), false);
    assert.equal(isActiveCallHistoryStage("upload_pending"), false);
  });

  it("calculates page counts and preserves URL-backed state safely", () => {
    assert.equal(callHistoryPageCount(0), 0);
    assert.equal(callHistoryPageCount(20), 1);
    assert.equal(callHistoryPageCount(21), 2);
    assert.equal(
      dashboardCallHistoryHref({
        workspaceId: "10000000-0000-0000-0000-000000000001",
        search: "A%,_(call)\\name",
        status: "failed",
        sort: "oldest",
        page: 3,
      }),
      "/dashboard?workspace=10000000-0000-0000-0000-000000000001&q=A%25%2C_%28call%29%5Cname&status=failed&sort=oldest&page=3",
    );
  });

  it("strictly parses bounded safe RPC output", () => {
    const valid = {
      items: [
        {
          id: "26000000-0000-4000-8000-000000000001",
          display_name: "Discovery call",
          original_filename: "source.mp3",
          uploaded_by: "00000000-0000-4000-8000-000000000001",
          content_type: "audio/mpeg",
          size_bytes: 1000,
          processing_stage: "transcribing",
          created_at: "2026-10-10T00:00:00Z",
          upload_completed_at: "2026-10-10T00:00:01Z",
        },
      ],
      page: 1,
      page_size: 20,
      total_count: 1,
      total_pages: 1,
      workspace_total_count: 1,
    };
    assert.equal(parseCallHistoryResponse(valid)?.items[0].displayName, "Discovery call");
    assert.equal(parseCallHistoryResponse({ ...valid, worker_error: "private" }), null);
    assert.equal(
      parseCallHistoryResponse({
        ...valid,
        items: [{ ...valid.items[0], claim_token: "private" }],
      }),
      null,
    );
    assert.equal(parseCallHistoryResponse({ ...valid, page_size: 500 }), null);
  });
});
