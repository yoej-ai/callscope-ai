export const PLAYBOOK_LIMITS: Readonly<{
  name: 120;
  vertical: 50;
  criterionName: 120;
  description: 1000;
  guidance: 2000;
  criteria: 20;
}>;

export type PlaybookStatus = "draft" | "published";
export type WorkspaceRole = "owner" | "admin" | "member";
export type CriterionInput = {
  name: string;
  description: string;
  weight: number;
  passGuidance: string;
  failGuidance: string;
};
export type PlaybookCriterion = CriterionInput & {
  id: string;
  playbookVersionId: string;
  position: number;
};
export type PlaybookVersion = {
  id: string;
  playbookId: string;
  versionNumber: number;
  status: PlaybookStatus;
  name: string;
  vertical: string;
  createdAt: string;
  updatedAt: string;
  publishedAt: string | null;
  criteria: PlaybookCriterion[];
};
export type Playbook = {
  id: string;
  workspaceId: string;
  createdAt: string;
  versions: PlaybookVersion[];
};

export function isPlaybookUuid(value: unknown): value is string;
export function normalizePlaybookName(value: unknown): string | null;
export function normalizePlaybookVertical(value: unknown): string | null;
export function normalizeCriterionName(value: unknown): string | null;
export function normalizeCriterionDescription(value: unknown): string | null;
export function normalizeCriterionGuidance(value: unknown): string | null;
export function parseCriterionWeight(value: unknown): number | null;
export function parseCriterionInput(value: unknown): CriterionInput | null;
export function totalCriterionWeight(
  criteria: Array<{ weight: number }>,
): number | null;
export function validateCriteriaForPublish(
  criteria: Array<{ name: string; weight: number; position: number }>,
): {
  valid: boolean;
  reason: "count" | "field" | "duplicate" | "order" | "weight" | null;
  totalWeight: number;
};
export function reorderCriteria<T extends { id: string; position: number }>(
  criteria: T[],
  criterionId: string,
  direction: "up" | "down",
): T[];
export function criterionEditorTransition(
  activeCriterionId: string | null,
  intent: "edit" | "cancel" | "save-success" | "save-failure",
  criterionId: string,
): string | null;
export function disclosureChevronDirection(open: boolean): "right" | "down";
export function nextDisclosureState(open: boolean, pending?: boolean): boolean;
export function pendingActionDisabled(
  disabled: boolean,
  pending: boolean,
): boolean;
export function publishedPlaybookEditAction(
  role: unknown,
  hasPublishedVersion: boolean,
  draftVersionNumber: number | null,
):
  | { kind: "continue"; label: string }
  | { kind: "create"; label: "Edit playbook" }
  | null;
export function publishedVersionPresentation<
  T extends { status: unknown; versionNumber: number },
>(versions: T[]): {
  current: T | null;
  previous: T[];
};
export function versionHistoryDisclosureState(
  open: boolean,
  count: number,
): {
  open: boolean;
  count: number;
  contentVisible: boolean;
  label: "Hide version history" | "View version history";
  chevron: "right" | "down";
};
export function publishedCriterionDisclosureState(open: boolean): {
  summaryVisible: true;
  detailsVisible: boolean;
  label: "Hide details" | "View details";
  chevron: "right" | "down";
};
export function publishShellState(
  confirming: boolean,
  pending: boolean,
  disabled?: boolean,
): {
  shellVisible: true;
  contentVisible: boolean;
  expanded: boolean;
  toggleDisabled: boolean;
  chevron: "right" | "down";
  actions: {
    keepEditing: {
      visible: true;
      disabled: boolean;
      label: "Keep editing";
    };
    confirmPublish: {
      visible: true;
      disabled: boolean;
      label: "Confirm publish" | "Publishing...";
      busy: boolean;
    };
  } | null;
};
export function parsePlaybookStatus(value: unknown): PlaybookStatus | null;
export function parseWorkspaceRole(value: unknown): WorkspaceRole | null;
export function canManagePlaybooks(role: unknown): boolean;
export function canEditPlaybookVersion(status: unknown, role: unknown): boolean;
export function playbookVersionLabel(
  versionNumber: number,
  status: unknown,
): string;
export function parsePlaybookData(
  value: { playbooks: unknown; versions: unknown; criteria: unknown },
  expectedWorkspaceId: string,
): Playbook[] | null;
