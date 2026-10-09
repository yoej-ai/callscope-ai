export type CallStatus =
  | "pending_upload"
  | "uploaded"
  | "processing"
  | "completed"
  | "failed"
  | "deleting";

export type ProcessingStatus =
  | "queued"
  | "processing"
  | "completed"
  | "failed";

export type RetryableStage = "transcription" | "analysis" | null;

export function callDisplayName(
  displayName: string | null,
  originalFilename: string,
): string;

export function callStatusLabel(status: string): string;

export function retryableProcessingStage(input: {
  callStatus: string;
  transcriptionStatus: ProcessingStatus | null;
  analysisStatus: ProcessingStatus | null;
}): RetryableStage;

export function canManageCall(input: {
  currentUserId: string;
  uploadedBy: string | null;
  workspaceRole: string | null;
}): boolean;
