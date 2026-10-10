const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CONTROL_CHARACTER_PATTERN = /[\u0000-\u001f\u007f-\u009f]/;

export const CALL_HISTORY_PAGE_SIZE = 20;
export const CALL_HISTORY_MAX_PAGE = 10000;

const STATUS_FILTERS = new Set([
  "all",
  "in_progress",
  "completed",
  "failed",
  "deleting",
]);

const SORT_ORDERS = new Set(["newest", "oldest"]);

const PROCESSING_STAGES = new Set([
  "upload_pending",
  "waiting_transcription",
  "transcribing",
  "waiting_analysis",
  "analyzing",
  "completed",
  "failed",
  "deleting",
]);

const ACTIVE_PROCESSING_STAGES = new Set([
  "waiting_transcription",
  "transcribing",
  "waiting_analysis",
  "analyzing",
]);

const RESPONSE_KEYS = [
  "items",
  "page",
  "page_size",
  "total_count",
  "total_pages",
  "workspace_total_count",
];

const ITEM_KEYS = [
  "id",
  "display_name",
  "original_filename",
  "uploaded_by",
  "content_type",
  "size_bytes",
  "processing_stage",
  "created_at",
  "upload_completed_at",
];

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasOnlyKeys(value, expectedKeys) {
  const keys = Object.keys(value).sort();
  const expected = [...expectedKeys].sort();
  return keys.length === expected.length && keys.every((key, index) => key === expected[index]);
}

function isTimestamp(value) {
  return typeof value === "string" && !Number.isNaN(Date.parse(value));
}

function isSafeCount(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

export function normalizeCallSearch(value) {
  const normalized = typeof value === "string" ? value.trim() : "";
  if (!normalized) return { value: "", error: null };
  if (normalized.length > 100 || CONTROL_CHARACTER_PATTERN.test(normalized)) {
    return {
      value: "",
      error: "Search must be 100 characters or fewer without control characters.",
    };
  }
  return { value: normalized, error: null };
}

export function parseCallHistoryStatus(value) {
  return typeof value === "string" && STATUS_FILTERS.has(value)
    ? value
    : "all";
}

export function parseCallHistorySort(value) {
  return typeof value === "string" && SORT_ORDERS.has(value)
    ? value
    : "newest";
}

export function parseCallHistoryPage(value) {
  if (typeof value !== "string" || !/^[1-9][0-9]*$/.test(value)) return 1;
  const page = Number(value);
  return Number.isSafeInteger(page) && page <= CALL_HISTORY_MAX_PAGE ? page : 1;
}

export function callHistoryStageLabel(stage) {
  const labels = {
    upload_pending: "Upload pending",
    waiting_transcription: "Waiting for transcription",
    transcribing: "Transcribing",
    waiting_analysis: "Waiting for AI analysis",
    analyzing: "Analyzing",
    completed: "Completed",
    failed: "Failed",
    deleting: "Deletion in progress",
  };
  return labels[stage] ?? "Processing status unavailable";
}

export function isActiveCallHistoryStage(stage) {
  return ACTIVE_PROCESSING_STAGES.has(stage);
}

export function callHistoryPageCount(totalCount) {
  return isSafeCount(totalCount)
    ? Math.ceil(totalCount / CALL_HISTORY_PAGE_SIZE)
    : 0;
}

export function dashboardCallHistoryHref({
  workspaceId,
  search = "",
  status = "all",
  sort = "newest",
  page = 1,
}) {
  const params = new URLSearchParams({ workspace: workspaceId });
  if (search) params.set("q", search);
  if (status !== "all") params.set("status", status);
  if (sort !== "newest") params.set("sort", sort);
  if (page > 1) params.set("page", String(page));
  return `/dashboard?${params.toString()}`;
}

function parseCallHistoryItem(value) {
  if (!isRecord(value) || !hasOnlyKeys(value, ITEM_KEYS)) return null;
  if (
    typeof value.id !== "string" ||
    !UUID_PATTERN.test(value.id) ||
    (value.display_name !== null &&
      (typeof value.display_name !== "string" ||
        !value.display_name.trim() ||
        value.display_name.length > 120 ||
        CONTROL_CHARACTER_PATTERN.test(value.display_name))) ||
    typeof value.original_filename !== "string" ||
    !value.original_filename.trim() ||
    (value.uploaded_by !== null &&
      (typeof value.uploaded_by !== "string" || !UUID_PATTERN.test(value.uploaded_by))) ||
    (value.content_type !== null && typeof value.content_type !== "string") ||
    (value.size_bytes !== null &&
      (!Number.isSafeInteger(value.size_bytes) || value.size_bytes < 1)) ||
    typeof value.processing_stage !== "string" ||
    !PROCESSING_STAGES.has(value.processing_stage) ||
    !isTimestamp(value.created_at) ||
    (value.upload_completed_at !== null && !isTimestamp(value.upload_completed_at))
  ) {
    return null;
  }

  return {
    id: value.id,
    displayName: value.display_name,
    originalFilename: value.original_filename,
    uploadedBy: value.uploaded_by,
    contentType: value.content_type,
    sizeBytes: value.size_bytes,
    processingStage: value.processing_stage,
    createdAt: value.created_at,
    uploadCompletedAt: value.upload_completed_at,
  };
}

export function parseCallHistoryResponse(value) {
  if (!isRecord(value) || !hasOnlyKeys(value, RESPONSE_KEYS)) return null;
  if (
    !Array.isArray(value.items) ||
    value.items.length > CALL_HISTORY_PAGE_SIZE ||
    !Number.isSafeInteger(value.page) ||
    value.page < 1 ||
    value.page_size !== CALL_HISTORY_PAGE_SIZE ||
    !isSafeCount(value.total_count) ||
    !isSafeCount(value.total_pages) ||
    !isSafeCount(value.workspace_total_count) ||
    value.workspace_total_count < value.total_count ||
    value.total_pages !== callHistoryPageCount(value.total_count) ||
    value.page > Math.max(1, value.total_pages)
  ) {
    return null;
  }

  const items = value.items.map(parseCallHistoryItem);
  if (items.some((item) => item === null)) return null;
  const ids = new Set(items.map((item) => item.id));
  if (ids.size !== items.length) return null;

  return {
    items,
    page: value.page,
    pageSize: value.page_size,
    totalCount: value.total_count,
    totalPages: value.total_pages,
    workspaceTotalCount: value.workspace_total_count,
  };
}
