export const PLAYBOOK_LIMITS = Object.freeze({
  name: 120,
  vertical: 50,
  criterionName: 120,
  description: 1000,
  guidance: 2000,
  criteria: 20,
});

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SINGLE_LINE_CONTROLS = /[\u0000-\u001f\u007f-\u009f]/u;
const MULTILINE_CONTROLS = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/u;
const VERTICAL_PATTERN = /^[a-z][a-z0-9_-]{0,49}$/u;
const PLAYBOOK_STATUSES = new Set(["draft", "published"]);
const WORKSPACE_ROLES = new Set(["owner", "admin", "member"]);

/** @param {unknown} value */
function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** @param {unknown} value */
export function isPlaybookUuid(value) {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

/** @param {unknown} value */
function isTimestamp(value) {
  return typeof value === "string" && !Number.isNaN(Date.parse(value));
}

/**
 * @param {unknown} value
 * @param {number} maximumLength
 */
function normalizeSingleLine(value, maximumLength) {
  if (typeof value !== "string") return null;
  const normalized = value.trim();
  if (
    !normalized ||
    normalized.length > maximumLength ||
    SINGLE_LINE_CONTROLS.test(normalized)
  ) {
    return null;
  }
  return normalized;
}

/**
 * @param {unknown} value
 * @param {number} maximumLength
 */
function normalizeMultiline(value, maximumLength) {
  if (typeof value !== "string") return null;
  const normalized = value.replace(/\r\n?/gu, "\n").trim();
  if (
    normalized.length > maximumLength ||
    MULTILINE_CONTROLS.test(normalized)
  ) {
    return null;
  }
  return normalized;
}

/** @param {unknown} value */
export function normalizePlaybookName(value) {
  return normalizeSingleLine(value, PLAYBOOK_LIMITS.name);
}

/** @param {unknown} value */
export function normalizePlaybookVertical(value) {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toLowerCase();
  return normalized.length <= PLAYBOOK_LIMITS.vertical &&
    VERTICAL_PATTERN.test(normalized)
    ? normalized
    : null;
}

/** @param {unknown} value */
export function normalizeCriterionName(value) {
  return normalizeSingleLine(value, PLAYBOOK_LIMITS.criterionName);
}

/** @param {unknown} value */
export function normalizeCriterionDescription(value) {
  return normalizeMultiline(value, PLAYBOOK_LIMITS.description);
}

/** @param {unknown} value */
export function normalizeCriterionGuidance(value) {
  return normalizeMultiline(value, PLAYBOOK_LIMITS.guidance);
}

/** @param {unknown} value */
export function parseCriterionWeight(value) {
  if (typeof value === "string" && !/^\d{1,3}$/u.test(value.trim())) {
    return null;
  }
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isSafeInteger(parsed) && parsed >= 1 && parsed <= 100
    ? parsed
    : null;
}

/** @param {unknown} value */
export function parseCriterionInput(value) {
  if (!isRecord(value)) return null;
  const name = normalizeCriterionName(value.name);
  const description = normalizeCriterionDescription(value.description);
  const weight = parseCriterionWeight(value.weight);
  const passGuidance = normalizeCriterionGuidance(value.passGuidance);
  const failGuidance = normalizeCriterionGuidance(value.failGuidance);
  if (
    name === null ||
    description === null ||
    weight === null ||
    passGuidance === null ||
    failGuidance === null
  ) {
    return null;
  }
  return { name, description, weight, passGuidance, failGuidance };
}

/** @param {Array<{weight: number}>} criteria */
export function totalCriterionWeight(criteria) {
  if (!Array.isArray(criteria) || criteria.length > PLAYBOOK_LIMITS.criteria) {
    return null;
  }
  let total = 0;
  for (const criterion of criteria) {
    const weight = parseCriterionWeight(criterion?.weight);
    if (weight === null) return null;
    total += weight;
  }
  return total;
}

/** @param {Array<{name: string, weight: number, position: number}>} criteria */
export function validateCriteriaForPublish(criteria) {
  if (
    !Array.isArray(criteria) ||
    criteria.length < 1 ||
    criteria.length > PLAYBOOK_LIMITS.criteria
  ) {
    return { valid: false, reason: "count", totalWeight: 0 };
  }

  const names = new Set();
  const positions = new Set();
  for (const criterion of criteria) {
    const name = normalizeCriterionName(criterion?.name);
    const weight = parseCriterionWeight(criterion?.weight);
    const position = criterion?.position;
    if (name === null || weight === null) {
      return { valid: false, reason: "field", totalWeight: 0 };
    }
    const nameKey = name.toLocaleLowerCase("en-US");
    if (names.has(nameKey)) {
      return { valid: false, reason: "duplicate", totalWeight: 0 };
    }
    if (
      !Number.isSafeInteger(position) ||
      position < 1 ||
      position > criteria.length ||
      positions.has(position)
    ) {
      return { valid: false, reason: "order", totalWeight: 0 };
    }
    names.add(nameKey);
    positions.add(position);
  }

  const totalWeight = totalCriterionWeight(criteria) ?? 0;
  return totalWeight === 100
    ? { valid: true, reason: null, totalWeight }
    : { valid: false, reason: "weight", totalWeight };
}

/**
 * @template {{id: string, position: number}} T
 * @param {T[]} criteria
 * @param {string} criterionId
 * @param {"up" | "down"} direction
 * @returns {T[]}
 */
export function reorderCriteria(criteria, criterionId, direction) {
  if (!Array.isArray(criteria) || !["up", "down"].includes(direction)) {
    return criteria;
  }
  const ordered = criteria
    .map((criterion) => ({ ...criterion }))
    .sort((left, right) => left.position - right.position);
  const index = ordered.findIndex((criterion) => criterion.id === criterionId);
  const adjacentIndex = direction === "up" ? index - 1 : index + 1;
  if (index < 0 || adjacentIndex < 0 || adjacentIndex >= ordered.length) {
    return ordered;
  }
  [ordered[index], ordered[adjacentIndex]] = [
    ordered[adjacentIndex],
    ordered[index],
  ];
  return ordered.map((criterion, nextIndex) => ({
    ...criterion,
    position: nextIndex + 1,
  }));
}

/**
 * Keep one criterion editor open at a time so switching cards never discards
 * unsaved input. A successful server action closes the active editor, while
 * a failed action keeps that same editor open.
 * @param {string | null} activeCriterionId
 * @param {"edit" | "cancel" | "save-success" | "save-failure"} intent
 * @param {string} criterionId
 */
export function criterionEditorTransition(
  activeCriterionId,
  intent,
  criterionId,
) {
  if (intent === "save-success") return null;
  if (intent === "save-failure") return criterionId;
  if (intent === "cancel") {
    return activeCriterionId === criterionId ? null : activeCriterionId;
  }
  if (intent === "edit") {
    return activeCriterionId === null || activeCriterionId === criterionId
      ? criterionId
      : activeCriterionId;
  }
  return activeCriterionId;
}

/** @param {boolean} open */
export function disclosureChevronDirection(open) {
  return open ? "down" : "right";
}

/** @param {boolean} open @param {boolean} pending */
export function nextDisclosureState(open, pending = false) {
  return pending ? open : !open;
}

/** @param {boolean} disabled @param {boolean} pending */
export function pendingActionDisabled(disabled, pending) {
  return Boolean(disabled || pending);
}

/**
 * Choose the only valid management action for a published playbook. Existing
 * drafts are resumed instead of creating another version.
 * @param {unknown} role
 * @param {boolean} hasPublishedVersion
 * @param {number | null} draftVersionNumber
 */
export function publishedPlaybookEditAction(
  role,
  hasPublishedVersion,
  draftVersionNumber,
) {
  if (!canManagePlaybooks(role) || !hasPublishedVersion) return null;
  if (
    Number.isSafeInteger(draftVersionNumber) &&
    draftVersionNumber >= 1 &&
    draftVersionNumber <= 10000
  ) {
    return {
      kind: "continue",
      label: `Continue editing Version ${draftVersionNumber}`,
    };
  }
  return { kind: "create", label: "Edit playbook" };
}

/**
 * Present one logical playbook with its newest published definition first and
 * immutable older definitions kept as secondary history.
 * @template {{status: unknown, versionNumber: number}} T
 * @param {T[]} versions
 */
export function publishedVersionPresentation(versions) {
  const ordered = Array.isArray(versions)
    ? versions
        .filter(
          (version) =>
            version?.status === "published" &&
            Number.isSafeInteger(version?.versionNumber),
        )
        .slice()
        .sort((left, right) => right.versionNumber - left.versionNumber)
    : [];
  return {
    current: ordered[0] ?? null,
    previous: ordered.slice(1),
  };
}

/** @param {boolean} open @param {number} count */
export function versionHistoryDisclosureState(open, count) {
  const safeCount = Number.isSafeInteger(count) && count > 0 ? count : 0;
  const expanded = Boolean(open && safeCount > 0);
  return {
    open: expanded,
    count: safeCount,
    contentVisible: expanded,
    label: expanded ? "Hide version history" : "View version history",
    chevron: disclosureChevronDirection(expanded),
  };
}

/** @param {boolean} open */
export function publishedCriterionDisclosureState(open) {
  const detailsVisible = Boolean(open);
  return {
    summaryVisible: true,
    detailsVisible,
    label: detailsVisible ? "Hide details" : "View details",
    chevron: disclosureChevronDirection(detailsVisible),
  };
}

/**
 * Keep the complete confirmation action set deterministic so the submit
 * control cannot disappear independently of the persistent shell.
 * @param {boolean} confirming
 * @param {boolean} pending
 * @param {boolean} disabled
 */
export function publishShellState(confirming, pending, disabled = false) {
  const contentVisible = Boolean(confirming || pending);
  return {
    shellVisible: true,
    contentVisible,
    expanded: contentVisible,
    toggleDisabled: Boolean(pending),
    chevron: disclosureChevronDirection(contentVisible),
    actions: contentVisible
      ? {
          keepEditing: {
            visible: true,
            disabled: Boolean(pending),
            label: "Keep editing",
          },
          confirmPublish: {
            visible: true,
            disabled: pendingActionDisabled(disabled, pending),
            label: pending ? "Publishing..." : "Confirm publish",
            busy: Boolean(pending),
          },
        }
      : null,
  };
}

/** @param {unknown} value */
export function parsePlaybookStatus(value) {
  return typeof value === "string" && PLAYBOOK_STATUSES.has(value)
    ? value
    : null;
}

/** @param {unknown} value */
export function parseWorkspaceRole(value) {
  return typeof value === "string" && WORKSPACE_ROLES.has(value)
    ? value
    : null;
}

/** @param {unknown} role */
export function canManagePlaybooks(role) {
  return role === "owner" || role === "admin";
}

/** @param {unknown} status @param {unknown} role */
export function canEditPlaybookVersion(status, role) {
  return status === "draft" && canManagePlaybooks(role);
}

/** @param {number} versionNumber @param {unknown} status */
export function playbookVersionLabel(versionNumber, status) {
  if (
    !Number.isSafeInteger(versionNumber) ||
    versionNumber < 1 ||
    versionNumber > 10000
  ) {
    return "Version unavailable";
  }
  const parsedStatus = parsePlaybookStatus(status);
  return parsedStatus
    ? `Version ${versionNumber} — ${parsedStatus === "draft" ? "Draft" : "Published"}`
    : `Version ${versionNumber}`;
}

/** @param {unknown} value */
function parseVersionRow(value) {
  if (!isRecord(value)) return null;
  const status = parsePlaybookStatus(value.status);
  const name = normalizePlaybookName(value.name);
  const vertical = normalizePlaybookVertical(value.vertical);
  if (
    !isPlaybookUuid(value.id) ||
    !isPlaybookUuid(value.playbook_id) ||
    !Number.isSafeInteger(value.version_number) ||
    value.version_number < 1 ||
    value.version_number > 10000 ||
    !status ||
    name !== value.name ||
    vertical !== value.vertical ||
    !isTimestamp(value.created_at) ||
    !isTimestamp(value.updated_at) ||
    (status === "draft" && value.published_at !== null) ||
    (status === "published" && !isTimestamp(value.published_at))
  ) {
    return null;
  }
  return {
    id: value.id,
    playbookId: value.playbook_id,
    versionNumber: value.version_number,
    status,
    name,
    vertical,
    createdAt: value.created_at,
    updatedAt: value.updated_at,
    publishedAt: value.published_at,
    criteria: [],
  };
}

/** @param {unknown} value */
function parseCriterionRow(value) {
  if (!isRecord(value)) return null;
  const name = normalizeCriterionName(value.name);
  const description = normalizeCriterionDescription(value.description);
  const weight = parseCriterionWeight(value.weight);
  const passGuidance = normalizeCriterionGuidance(value.pass_guidance);
  const failGuidance = normalizeCriterionGuidance(value.fail_guidance);
  if (
    !isPlaybookUuid(value.id) ||
    !isPlaybookUuid(value.playbook_version_id) ||
    name !== value.name ||
    description !== value.description ||
    weight === null ||
    passGuidance !== value.pass_guidance ||
    failGuidance !== value.fail_guidance ||
    !Number.isSafeInteger(value.position) ||
    value.position < 1 ||
    value.position > PLAYBOOK_LIMITS.criteria
  ) {
    return null;
  }
  return {
    id: value.id,
    playbookVersionId: value.playbook_version_id,
    name,
    description,
    weight,
    passGuidance,
    failGuidance,
    position: value.position,
  };
}

/**
 * Parse only the bounded fields selected by the playbook pages.
 * @param {{playbooks: unknown, versions: unknown, criteria: unknown}} value
 * @param {string} expectedWorkspaceId
 */
export function parsePlaybookData(value, expectedWorkspaceId) {
  if (
    !isRecord(value) ||
    !isPlaybookUuid(expectedWorkspaceId) ||
    !Array.isArray(value.playbooks) ||
    !Array.isArray(value.versions) ||
    !Array.isArray(value.criteria) ||
    value.playbooks.length > 100 ||
    value.versions.length > 1000 ||
    value.criteria.length > 2000
  ) {
    return null;
  }

  const playbooks = [];
  const playbookById = new Map();
  for (const row of value.playbooks) {
    if (
      !isRecord(row) ||
      !isPlaybookUuid(row.id) ||
      row.workspace_id !== expectedWorkspaceId ||
      !isTimestamp(row.created_at) ||
      playbookById.has(row.id)
    ) {
      return null;
    }
    const playbook = {
      id: row.id,
      workspaceId: expectedWorkspaceId,
      createdAt: row.created_at,
      versions: [],
    };
    playbooks.push(playbook);
    playbookById.set(playbook.id, playbook);
  }

  const versionById = new Map();
  for (const row of value.versions) {
    const version = parseVersionRow(row);
    const playbook = version ? playbookById.get(version.playbookId) : null;
    if (!version || !playbook || versionById.has(version.id)) return null;
    if (
      playbook.versions.some(
        (existing) => existing.versionNumber === version.versionNumber,
      )
    ) {
      return null;
    }
    playbook.versions.push(version);
    versionById.set(version.id, version);
  }

  for (const row of value.criteria) {
    const criterion = parseCriterionRow(row);
    const version = criterion
      ? versionById.get(criterion.playbookVersionId)
      : null;
    if (!criterion || !version) return null;
    if (
      version.criteria.some(
        (existing) =>
          existing.id === criterion.id ||
          existing.position === criterion.position ||
          existing.name.toLocaleLowerCase("en-US") ===
            criterion.name.toLocaleLowerCase("en-US"),
      )
    ) {
      return null;
    }
    version.criteria.push(criterion);
  }

  for (const playbook of playbooks) {
    playbook.versions.sort(
      (left, right) => left.versionNumber - right.versionNumber,
    );
    if (playbook.versions.filter((version) => version.status === "draft").length > 1) {
      return null;
    }
    for (const version of playbook.versions) {
      version.criteria.sort((left, right) => left.position - right.position);
      if (
        version.status === "published" &&
        !validateCriteriaForPublish(version.criteria).valid
      ) {
        return null;
      }
    }
  }

  return playbooks.sort((left, right) =>
    left.createdAt === right.createdAt
      ? left.id.localeCompare(right.id)
      : left.createdAt.localeCompare(right.createdAt),
  );
}
