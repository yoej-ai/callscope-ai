import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

import {
  canManageSpeakerAttribution,
  formatTranscriptTimestamp,
  parseQueueSpeakerAttributionResult,
  parseSpeakerAttributionStatus,
  speakerDisplayLabel,
} from "../lib/speaker-turns.mjs";

describe("speaker-attributed transcript presentation", () => {
  it("formats stored integer milliseconds without floating-point output", () => {
    assert.equal(formatTranscriptTimestamp(0), "00:00");
    assert.equal(formatTranscriptTimestamp(84_999), "01:24");
    assert.equal(formatTranscriptTimestamp(3_738_000), "1:02:18");
    assert.equal(formatTranscriptTimestamp(3_600_000), "1:00:00");
    assert.equal(formatTranscriptTimestamp(1.5), "--:--");
  });

  it("shows trusted roles and stable anonymous fallbacks", () => {
    assert.equal(speakerDisplayLabel("agent", "speaker_2"), "Agent");
    assert.equal(speakerDisplayLabel("customer", "speaker_1"), "Customer");
    assert.equal(speakerDisplayLabel("unknown", "speaker_1"), "Speaker 1");
    assert.equal(speakerDisplayLabel("unknown", "speaker_8"), "Speaker 8");
    assert.equal(speakerDisplayLabel("unknown", "unknown"), "Speaker");
  });

  it("limits manual queue controls to owners and admins", () => {
    assert.equal(canManageSpeakerAttribution("owner"), true);
    assert.equal(canManageSpeakerAttribution("admin"), true);
    assert.equal(canManageSpeakerAttribution("member"), false);
  });

  it("parses lifecycle and bounded manual queue results", () => {
    const callId = "20000000-0000-4000-8000-000000000091";
    assert.equal(parseSpeakerAttributionStatus("processing"), "processing");
    assert.equal(parseSpeakerAttributionStatus("leased"), null);
    assert.deepEqual(
      parseQueueSpeakerAttributionResult([
        { call_id: callId, status: "queued", created: true },
      ]),
      { callId, status: "queued", created: true },
    );
    assert.deepEqual(
      parseQueueSpeakerAttributionResult([
        { call_id: null, status: "ineligible", created: false },
      ]),
      { callId: null, status: "ineligible", created: false },
    );
    assert.equal(
      parseQueueSpeakerAttributionResult([
        { call_id: callId, status: "queued", created: true, claim_token: "hidden" },
      ]),
      null,
    );
  });

  it("renders completed turns and every safe fallback state", async () => {
    const [page, action] = await Promise.all([
      readFile(
        new URL("../app/dashboard/calls/[callId]/page.tsx", import.meta.url),
        "utf8",
      ),
      readFile(
        new URL("../components/speaker-attribution-action.tsx", import.meta.url),
        "utf8",
      ),
    ]);
    assert.match(page, /Speaker-attributed transcript/);
    assert.match(page, /Preparing speaker labels/);
    assert.match(page, /Identifying speakers/);
    assert.match(page, /Speaker labels could not be prepared/);
    assert.match(page, /View plain transcript/);
    assert.match(action, /Add speaker labels/);
  });

  it("queries only browser-safe speaker columns", async () => {
    const loader = await readFile(
      new URL("../lib/speaker-data.ts", import.meta.url),
      "utf8",
    );
    assert.doesNotMatch(loader, /claim_token|lease_expires_at|next_attempt_at|last_error_code|attempt_count/);
    assert.match(loader, /call_id, status, completed_at/);
    assert.match(loader, /turn_index, start_ms, end_ms, text, speaker_key, speaker_role/);
  });
});
