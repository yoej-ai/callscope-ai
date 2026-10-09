import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  callDisplayName,
  callStatusLabel,
  canManageCall,
  retryableProcessingStage,
} from "../lib/call-management.mjs";

describe("call management presentation logic", () => {
  it("uses a normalized display name with the source filename as fallback", () => {
    assert.equal(callDisplayName(" Discovery call ", "source.mp3"), "Discovery call");
    assert.equal(callDisplayName(null, "source.mp3"), "source.mp3");
    assert.equal(callDisplayName("   ", "source.mp3"), "source.mp3");
  });

  it("presents deleting as a distinct lifecycle state", () => {
    assert.equal(callStatusLabel("deleting"), "Deletion in progress");
  });

  it("offers manual retry only for the terminal failed stage", () => {
    assert.equal(
      retryableProcessingStage({
        callStatus: "uploaded",
        transcriptionStatus: "failed",
        analysisStatus: null,
      }),
      "transcription",
    );
    assert.equal(
      retryableProcessingStage({
        callStatus: "uploaded",
        transcriptionStatus: "completed",
        analysisStatus: "failed",
      }),
      "analysis",
    );
    assert.equal(
      retryableProcessingStage({
        callStatus: "deleting",
        transcriptionStatus: "failed",
        analysisStatus: null,
      }),
      null,
    );
    assert.equal(
      retryableProcessingStage({
        callStatus: "uploaded",
        transcriptionStatus: "processing",
        analysisStatus: null,
      }),
      null,
    );
  });

  it("shows management controls only to the uploader or workspace managers", () => {
    const input = {
      currentUserId: "user-a",
      uploadedBy: "user-b",
      workspaceRole: "member",
    };
    assert.equal(canManageCall(input), false);
    assert.equal(canManageCall({ ...input, uploadedBy: "user-a" }), true);
    assert.equal(canManageCall({ ...input, workspaceRole: "admin" }), true);
    assert.equal(canManageCall({ ...input, workspaceRole: "owner" }), true);
  });
});
