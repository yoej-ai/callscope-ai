import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  canEditPlaybookVersion,
  canManagePlaybooks,
  criterionEditorTransition,
  disclosureChevronDirection,
  normalizeCriterionDescription,
  normalizeCriterionGuidance,
  normalizeCriterionName,
  normalizePlaybookName,
  normalizePlaybookVertical,
  nextDisclosureState,
  parseCriterionInput,
  parseCriterionWeight,
  parsePlaybookData,
  parsePlaybookStatus,
  parseWorkspaceRole,
  pendingActionDisabled,
  PLAYBOOK_LIMITS,
  publishedCriterionDisclosureState,
  publishedPlaybookEditAction,
  publishShellState,
  playbookVersionLabel,
  reorderCriteria,
  totalCriterionWeight,
  validateCriteriaForPublish,
} from "../lib/playbooks.mjs";

const WORKSPACE_ID = "10000000-0000-4000-8000-000000000081";
const PLAYBOOK_ID = "20000000-0000-4000-8000-000000000081";
const VERSION_ID = "30000000-0000-4000-8000-000000000081";
const CRITERION_ID = "40000000-0000-4000-8000-000000000081";

describe("playbook field normalization", () => {
  it("normalizes required single-line fields and vertical slugs", () => {
    assert.equal(normalizePlaybookName("  Sales discovery  "), "Sales discovery");
    assert.equal(normalizeCriterionName("  Clear next step "), "Clear next step");
    assert.equal(normalizePlaybookVertical(" Sales "), "sales");
    assert.equal(normalizePlaybookVertical("customer-success"), "customer-success");
  });

  it("rejects blank, controlled, malformed, and overlong fields", () => {
    assert.equal(normalizePlaybookName("   "), null);
    assert.equal(normalizePlaybookName("Name\nspoof"), null);
    assert.equal(normalizeCriterionName("x".repeat(PLAYBOOK_LIMITS.criterionName + 1)), null);
    assert.equal(normalizePlaybookVertical("Sales team"), null);
    assert.equal(normalizePlaybookVertical("https://example.com"), null);
  });

  it("normalizes bounded multiline guidance without accepting unsafe controls", () => {
    assert.equal(
      normalizeCriterionDescription("  Ask about goals.\r\nConfirm impact.  "),
      "Ask about goals.\nConfirm impact.",
    );
    assert.equal(normalizeCriterionGuidance("Good\tcontext"), "Good\tcontext");
    assert.equal(normalizeCriterionGuidance("bad\u0001value"), null);
    assert.equal(
      normalizeCriterionDescription("x".repeat(PLAYBOOK_LIMITS.description + 1)),
      null,
    );
  });
});

describe("criterion validation and ordering", () => {
  it("strictly parses a complete bounded criterion", () => {
    assert.deepEqual(
      parseCriterionInput({
        name: " Discovery ",
        description: " Understand the buyer. ",
        weight: "25",
        passGuidance: " Open questions ",
        failGuidance: " Assumptions only ",
      }),
      {
        name: "Discovery",
        description: "Understand the buyer.",
        weight: 25,
        passGuidance: "Open questions",
        failGuidance: "Assumptions only",
      },
    );
    assert.equal(parseCriterionInput({ name: "Discovery", weight: "1.5" }), null);
  });

  it("accepts only whole weights from 1 through 100", () => {
    assert.equal(parseCriterionWeight("1"), 1);
    assert.equal(parseCriterionWeight(100), 100);
    for (const value of [0, 101, -1, 1.5, "", "1e2", "10.0", null]) {
      assert.equal(parseCriterionWeight(value), null);
    }
  });

  it("calculates totals and enforces the publish invariants", () => {
    const criteria = [
      { name: "Greeting", weight: 20, position: 1 },
      { name: "Discovery", weight: 50, position: 2 },
      { name: "Next step", weight: 30, position: 3 },
    ];
    assert.equal(totalCriterionWeight(criteria), 100);
    assert.deepEqual(validateCriteriaForPublish(criteria), {
      valid: true,
      reason: null,
      totalWeight: 100,
    });
    assert.equal(
      validateCriteriaForPublish(criteria.map((item) => ({ ...item, weight: 10 }))).reason,
      "weight",
    );
    assert.equal(
      validateCriteriaForPublish([
        criteria[0],
        { ...criteria[1], name: "greeting" },
      ]).reason,
      "duplicate",
    );
    assert.equal(
      validateCriteriaForPublish([{ ...criteria[0], position: 2 }]).reason,
      "order",
    );
  });

  it("enforces the maximum criterion count", () => {
    const maximum = Array.from({ length: PLAYBOOK_LIMITS.criteria }, (_, index) => ({
      name: `Criterion ${index + 1}`,
      weight: 5,
      position: index + 1,
    }));
    assert.equal(validateCriteriaForPublish(maximum).valid, true);
    assert.equal(
      validateCriteriaForPublish([
        ...maximum,
        { name: "Too many", weight: 1, position: 21 },
      ]).reason,
      "count",
    );
  });

  it("reorders criteria without changing their identifiers", () => {
    const criteria = [
      { id: "a", position: 1, name: "Greeting" },
      { id: "b", position: 2, name: "Discovery" },
      { id: "c", position: 3, name: "Closing" },
    ];
    assert.deepEqual(
      reorderCriteria(criteria, "b", "up").map(({ id, position }) => ({ id, position })),
      [
        { id: "b", position: 1 },
        { id: "a", position: 2 },
        { id: "c", position: 3 },
      ],
    );
    assert.deepEqual(reorderCriteria(criteria, "a", "up"), criteria);
  });
});

describe("playbook editor presentation state", () => {
  it("keeps saved criteria collapsed until Edit is requested", () => {
    assert.equal(criterionEditorTransition(null, "save-success", CRITERION_ID), null);
    assert.equal(criterionEditorTransition(null, "edit", CRITERION_ID), CRITERION_ID);
    assert.equal(
      criterionEditorTransition(CRITERION_ID, "cancel", CRITERION_ID),
      null,
    );
  });

  it("keeps a failed save open and protects another unsaved editor", () => {
    assert.equal(
      criterionEditorTransition(null, "save-failure", CRITERION_ID),
      CRITERION_ID,
    );
    assert.equal(
      criterionEditorTransition(CRITERION_ID, "edit", "criterion-two"),
      CRITERION_ID,
    );
  });

  it("maps a visible chevron for both disclosure states", () => {
    assert.equal(disclosureChevronDirection(false), "right");
    assert.equal(disclosureChevronDirection(true), "down");
  });

  it("opens and closes Add Criterion and publish disclosures without collapsing pending UI", () => {
    assert.equal(nextDisclosureState(false), true);
    assert.equal(nextDisclosureState(true), false);
    assert.equal(nextDisclosureState(true, true), true);
  });

  it("blocks duplicate actions while pending without changing base availability", () => {
    assert.equal(pendingActionDisabled(false, false), false);
    assert.equal(pendingActionDisabled(false, true), true);
    assert.equal(pendingActionDisabled(true, false), true);
  });

  it("creates a draft for published editing and resumes an existing draft", () => {
    assert.deepEqual(publishedPlaybookEditAction("owner", true, null), {
      kind: "create",
      label: "Edit playbook",
    });
    assert.deepEqual(publishedPlaybookEditAction("admin", true, 3), {
      kind: "continue",
      label: "Continue editing Version 3",
    });
    assert.equal(publishedPlaybookEditAction("member", true, null), null);
    assert.equal(publishedPlaybookEditAction("owner", false, null), null);
  });

  it("keeps published criterion summaries visible while details disclose", () => {
    assert.deepEqual(publishedCriterionDisclosureState(false), {
      summaryVisible: true,
      detailsVisible: false,
      label: "View details",
      chevron: "right",
    });
    assert.deepEqual(publishedCriterionDisclosureState(true), {
      summaryVisible: true,
      detailsVisible: true,
      label: "Hide details",
      chevron: "down",
    });
  });

  it("keeps the closed publish shell mounted without confirmation actions", () => {
    const state = publishShellState(false, false);
    assert.equal(state.shellVisible, true);
    assert.equal(state.contentVisible, false);
    assert.equal(state.chevron, "right");
    assert.equal(state.actions, null);
  });

  it("renders Keep editing and Confirm publish together for a valid confirmation", () => {
    const state = publishShellState(true, false, false);
    assert.equal(state.shellVisible, true);
    assert.equal(state.contentVisible, true);
    assert.equal(state.expanded, true);
    assert.equal(state.chevron, "down");
    assert.deepEqual(state.actions, {
      keepEditing: {
        visible: true,
        disabled: false,
        label: "Keep editing",
      },
      confirmPublish: {
        visible: true,
        disabled: false,
        label: "Confirm publish",
        busy: false,
      },
    });
  });

  it("keeps invalid confirmation understandable but blocks submit", () => {
    const state = publishShellState(true, false, true);
    assert.equal(state.actions?.keepEditing.visible, true);
    assert.equal(state.actions?.keepEditing.disabled, false);
    assert.equal(state.actions?.confirmPublish.visible, true);
    assert.equal(state.actions?.confirmPublish.disabled, true);
    assert.equal(state.actions?.confirmPublish.label, "Confirm publish");
  });

  it("keeps a stable pending submit action and blocks duplicate submission", () => {
    const state = publishShellState(false, true, false);
    assert.equal(state.shellVisible, true);
    assert.equal(state.contentVisible, true);
    assert.equal(state.toggleDisabled, true);
    assert.equal(state.actions?.keepEditing.disabled, true);
    assert.equal(state.actions?.confirmPublish.visible, true);
    assert.equal(state.actions?.confirmPublish.disabled, true);
    assert.equal(state.actions?.confirmPublish.label, "Publishing...");
    assert.equal(state.actions?.confirmPublish.busy, true);
  });

  it("restores both usable actions after a recoverable publish error", () => {
    const state = publishShellState(true, false, false);
    assert.equal(state.shellVisible, true);
    assert.equal(state.contentVisible, true);
    assert.equal(state.actions?.keepEditing.disabled, false);
    assert.equal(state.actions?.confirmPublish.disabled, false);
    assert.equal(state.actions?.confirmPublish.label, "Confirm publish");
  });
});

describe("playbook state and response safety", () => {
  it("parses only supported lifecycle and workspace roles", () => {
    assert.equal(parsePlaybookStatus("draft"), "draft");
    assert.equal(parsePlaybookStatus("published"), "published");
    assert.equal(parsePlaybookStatus("archived"), null);
    assert.equal(parseWorkspaceRole("owner"), "owner");
    assert.equal(parseWorkspaceRole("admin"), "admin");
    assert.equal(parseWorkspaceRole("member"), "member");
    assert.equal(parseWorkspaceRole("service_role"), null);
  });

  it("allows management only for owners and admins", () => {
    assert.equal(canManagePlaybooks("owner"), true);
    assert.equal(canManagePlaybooks("admin"), true);
    assert.equal(canManagePlaybooks("member"), false);
    assert.equal(canManagePlaybooks("authenticated"), false);
  });

  it("keeps published versions read-only for every role", () => {
    assert.equal(canEditPlaybookVersion("draft", "owner"), true);
    assert.equal(canEditPlaybookVersion("draft", "admin"), true);
    assert.equal(canEditPlaybookVersion("draft", "member"), false);
    assert.equal(canEditPlaybookVersion("published", "owner"), false);
    assert.equal(canEditPlaybookVersion("published", "admin"), false);
  });

  it("formats stable version labels", () => {
    assert.equal(playbookVersionLabel(1, "draft"), "Version 1 — Draft");
    assert.equal(playbookVersionLabel(2, "published"), "Version 2 — Published");
    assert.equal(playbookVersionLabel(0, "draft"), "Version unavailable");
  });

  it("strictly parses bounded tenant-scoped database results", () => {
    const payload = {
      playbooks: [
        {
          id: PLAYBOOK_ID,
          workspace_id: WORKSPACE_ID,
          created_at: "2026-10-13T00:00:00.000Z",
        },
      ],
      versions: [
        {
          id: VERSION_ID,
          playbook_id: PLAYBOOK_ID,
          version_number: 1,
          status: "published",
          name: "Sales discovery",
          vertical: "sales",
          created_at: "2026-10-13T00:00:00.000Z",
          updated_at: "2026-10-13T01:00:00.000Z",
          published_at: "2026-10-13T01:00:00.000Z",
        },
      ],
      criteria: [
        {
          id: CRITERION_ID,
          playbook_version_id: VERSION_ID,
          name: "Discovery",
          description: "Understand the buyer.",
          weight: 100,
          pass_guidance: "Open questions",
          fail_guidance: "Assumptions only",
          position: 1,
        },
      ],
    };

    const parsed = parsePlaybookData(payload, WORKSPACE_ID);
    assert.equal(parsed?.[0]?.versions[0]?.criteria[0]?.name, "Discovery");
    assert.equal(
      parsePlaybookData(payload, "10000000-0000-4000-8000-000000000099"),
      null,
    );
    assert.equal(
      parsePlaybookData(
        {
          ...payload,
          versions: [{ ...payload.versions[0], status: "draft", published_at: null }],
          criteria: [{ ...payload.criteria[0], weight: 101 }],
        },
        WORKSPACE_ID,
      ),
      null,
    );
  });
});
