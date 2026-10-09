export function callDisplayName(displayName, originalFilename) {
  const normalized = typeof displayName === "string" ? displayName.trim() : "";
  return normalized || originalFilename;
}

export function callStatusLabel(status) {
  const labels = {
    pending_upload: "Upload pending",
    uploaded: "Upload complete",
    processing: "Upload processing",
    completed: "Upload complete",
    failed: "Upload failed",
    deleting: "Deletion in progress",
  };

  return labels[status] ?? "Call status unavailable";
}

export function retryableProcessingStage({
  callStatus,
  transcriptionStatus,
  analysisStatus,
}) {
  if (callStatus === "deleting") return null;
  if (transcriptionStatus === "failed") return "transcription";
  if (transcriptionStatus === "completed" && analysisStatus === "failed") {
    return "analysis";
  }
  return null;
}

export function canManageCall({ currentUserId, uploadedBy, workspaceRole }) {
  if (!currentUserId) return false;
  return (
    uploadedBy === currentUserId ||
    workspaceRole === "owner" ||
    workspaceRole === "admin"
  );
}
