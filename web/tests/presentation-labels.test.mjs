import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { humanizeDisplayLabel } from "../lib/presentation/labels.mjs";

describe("humanizeDisplayLabel", () => {
  it("turns machine-style underscore values into readable labels", () => {
    assert.equal(
      humanizeDisplayLabel("Schedule_business_consultation"),
      "Schedule business consultation",
    );
    assert.equal(
      humanizeDisplayLabel("marketing_strategies"),
      "Marketing strategies",
    );
  });

  it("normalizes surrounding and repeated whitespace", () => {
    assert.equal(
      humanizeDisplayLabel("  customer__engagement   plan  "),
      "Customer engagement plan",
    );
  });

  it("preserves meaningful capitalization after the first character", () => {
    assert.equal(humanizeDisplayLabel("CRM_follow_up"), "CRM follow up");
  });

  it("returns an empty string for whitespace-only values", () => {
    assert.equal(humanizeDisplayLabel("   "), "");
  });
});
