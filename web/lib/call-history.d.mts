export type CallHistoryStatus =
  | "all"
  | "in_progress"
  | "completed"
  | "failed"
  | "deleting";

export type CallHistorySort = "newest" | "oldest";

export type CallProcessingStage =
  | "upload_pending"
  | "waiting_transcription"
  | "transcribing"
  | "waiting_analysis"
  | "analyzing"
  | "completed"
  | "failed"
  | "deleting";

export type CallHistoryItem = {
  id: string;
  displayName: string | null;
  originalFilename: string;
  uploadedBy: string | null;
  contentType: string | null;
  sizeBytes: number | null;
  processingStage: CallProcessingStage;
  createdAt: string;
  uploadCompletedAt: string | null;
};

export type CallHistoryResponse = {
  items: CallHistoryItem[];
  page: number;
  pageSize: 20;
  totalCount: number;
  totalPages: number;
  workspaceTotalCount: number;
};

export const CALL_HISTORY_PAGE_SIZE: 20;
export const CALL_HISTORY_MAX_PAGE: 10000;

export function normalizeCallSearch(value: unknown): {
  value: string;
  error: string | null;
};
export function parseCallHistoryStatus(value: unknown): CallHistoryStatus;
export function parseCallHistorySort(value: unknown): CallHistorySort;
export function parseCallHistoryPage(value: unknown): number;
export function callHistoryStageLabel(stage: string): string;
export function isActiveCallHistoryStage(stage: string): boolean;
export function callHistoryPageCount(totalCount: number): number;
export function dashboardCallHistoryHref(input: {
  workspaceId: string;
  search?: string;
  status?: CallHistoryStatus;
  sort?: CallHistorySort;
  page?: number;
}): string;
export function parseCallHistoryResponse(value: unknown): CallHistoryResponse | null;
