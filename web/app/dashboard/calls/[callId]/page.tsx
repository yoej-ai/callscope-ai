import Link from "next/link";
import { notFound, redirect } from "next/navigation";

import { DashboardNav } from "@/components/dashboard-nav";
import { isUuid } from "@/lib/api/types";
import { createClient } from "@/lib/supabase/server";

type CallDetailPageProps = {
  params: Promise<{ callId: string }>;
};

const CALL_STATUSES = new Set([
  "pending_upload",
  "uploaded",
  "processing",
  "completed",
  "failed",
]);
const TRANSCRIPTION_STATUSES = new Set([
  "queued",
  "processing",
  "completed",
  "failed",
]);

type CallDetail = {
  id: string;
  workspaceId: string;
  originalFilename: string;
  status: string;
  durationSeconds: number | null;
  createdAt: string;
  uploadCompletedAt: string | null;
};

type TranscriptionDetail = {
  status: "queued" | "processing" | "completed" | "failed";
  transcriptText: string | null;
  languageCode: string | null;
  startedAt: string | null;
  completedAt: string | null;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isTimestamp(value: unknown): value is string {
  return typeof value === "string" && !Number.isNaN(Date.parse(value));
}

function parseCallDetail(value: unknown, callId: string): CallDetail | null {
  if (!isRecord(value)) return null;

  if (
    value.id !== callId ||
    !isUuid(value.workspace_id) ||
    typeof value.original_filename !== "string" ||
    !value.original_filename.trim() ||
    typeof value.status !== "string" ||
    !CALL_STATUSES.has(value.status) ||
    (value.duration_seconds !== null &&
      (typeof value.duration_seconds !== "number" ||
        !Number.isSafeInteger(value.duration_seconds) ||
        value.duration_seconds < 0)) ||
    !isTimestamp(value.created_at) ||
    (value.upload_completed_at !== null &&
      !isTimestamp(value.upload_completed_at))
  ) {
    return null;
  }

  return {
    id: value.id,
    workspaceId: value.workspace_id,
    originalFilename: value.original_filename,
    status: value.status,
    durationSeconds: value.duration_seconds,
    createdAt: value.created_at,
    uploadCompletedAt: value.upload_completed_at,
  };
}

function parseTranscriptionDetail(value: unknown): TranscriptionDetail | null {
  if (!isRecord(value)) return null;
  if (
    typeof value.status !== "string" ||
    !TRANSCRIPTION_STATUSES.has(value.status) ||
    (value.transcript_text !== null &&
      typeof value.transcript_text !== "string") ||
    (value.language_code !== null &&
      typeof value.language_code !== "string") ||
    (value.started_at !== null && !isTimestamp(value.started_at)) ||
    (value.completed_at !== null && !isTimestamp(value.completed_at))
  ) {
    return null;
  }

  if (
    value.status === "completed" &&
    (typeof value.transcript_text !== "string" ||
      !value.transcript_text.trim() ||
      !isTimestamp(value.completed_at))
  ) {
    return null;
  }

  return {
    status: value.status as TranscriptionDetail["status"],
    transcriptText: value.transcript_text,
    languageCode: value.language_code,
    startedAt: value.started_at,
    completedAt: value.completed_at,
  };
}

function formatDate(value: string) {
  return new Intl.DateTimeFormat("en-AU", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}

function formatDuration(durationSeconds: number | null) {
  if (durationSeconds === null) return "Not available";
  const minutes = Math.floor(durationSeconds / 60);
  const seconds = durationSeconds % 60;
  return minutes > 0 ? `${minutes}m ${seconds}s` : `${seconds}s`;
}

function statusLabel(status: string) {
  return status.replaceAll("_", " ");
}

function TranscriptionPanel({
  transcription,
  unavailable,
}: {
  transcription: TranscriptionDetail | null;
  unavailable: boolean;
}) {
  if (unavailable) {
    return (
      <div className="transcript-state" role="alert">
        <h2>Transcript unavailable</h2>
        <p>We could not securely load the transcription state. Try again later.</p>
      </div>
    );
  }

  if (!transcription) {
    return (
      <div className="transcript-state">
        <h2>Transcription not queued</h2>
        <p>No transcription record is available for this call yet.</p>
      </div>
    );
  }

  if (transcription.status === "queued") {
    return (
      <div className="transcript-state">
        <h2>Queued for transcription</h2>
        <p>A trusted worker can process this recording in a later phase.</p>
      </div>
    );
  }

  if (transcription.status === "processing") {
    return (
      <div className="transcript-state" aria-live="polite">
        <h2>Transcription in progress</h2>
        <p>The recording is currently held by a trusted worker lease.</p>
      </div>
    );
  }

  if (transcription.status === "failed") {
    return (
      <div className="transcript-state" role="status">
        <h2>Transcription failed</h2>
        <p>The recording could not be transcribed. Internal worker details remain private.</p>
      </div>
    );
  }

  return (
    <div className="transcript-result">
      <div className="section-heading">
        <div>
          <p className="eyebrow">Transcript</p>
          <h2>Completed transcription</h2>
        </div>
        {transcription.languageCode && (
          <span className="call-count">{transcription.languageCode}</span>
        )}
      </div>
      <p className="transcript-text">{transcription.transcriptText}</p>
      {transcription.completedAt && (
        <p className="transcript-timestamp">
          Completed {formatDate(transcription.completedAt)}
        </p>
      )}
    </div>
  );
}

export default async function CallDetailPage({ params }: CallDetailPageProps) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/sign-in?message=Please%20sign%20in%20to%20continue.");
  }

  const { callId } = await params;
  if (!isUuid(callId)) notFound();

  const { data: callRow, error: callError } = await supabase
    .from("calls")
    .select(
      "id, workspace_id, original_filename, status, duration_seconds, created_at, upload_completed_at",
    )
    .eq("id", callId)
    .maybeSingle();

  const call = parseCallDetail(callRow, callId);
  if (callError || !call) {
    notFound();
  }

  const { data: transcriptionRow, error: transcriptionError } = await supabase
    .from("call_transcriptions")
    .select(
      "status, transcript_text, language_code, started_at, completed_at",
    )
    .eq("call_id", call.id)
    .maybeSingle();

  const transcription = transcriptionRow
    ? parseTranscriptionDetail(transcriptionRow)
    : null;
  const transcriptionUnavailable =
    Boolean(transcriptionError) || Boolean(transcriptionRow && !transcription);

  if (transcriptionError) {
    console.error("Unable to load call transcription", {
      code: transcriptionError.code,
    });
  } else if (transcriptionRow && !transcription) {
    console.error("Call transcription response was invalid");
  }

  return (
    <div className="dashboard-shell">
      <DashboardNav email={user.email ?? "Signed-in user"} />
      <main className="dashboard-main call-detail-main">
        <Link
          className="text-link back-link"
          href={`/dashboard?workspace=${encodeURIComponent(call.workspaceId)}`}
        >
          ← Back to dashboard
        </Link>

        <article className="call-detail-card" aria-labelledby="call-detail-title">
          <header className="call-detail-header">
            <div>
              <p className="eyebrow">Call detail</p>
              <h1 id="call-detail-title">{call.originalFilename}</h1>
            </div>
            <span className={`call-status ${call.status}`}>
              {statusLabel(call.status)}
            </span>
          </header>

          <dl className="call-metadata">
            <div>
              <dt>Upload state</dt>
              <dd>{statusLabel(call.status)}</dd>
            </div>
            <div>
              <dt>Duration</dt>
              <dd>{formatDuration(call.durationSeconds)}</dd>
            </div>
            <div>
              <dt>Added</dt>
              <dd>{formatDate(call.uploadCompletedAt ?? call.createdAt)}</dd>
            </div>
            <div>
              <dt>Transcription state</dt>
              <dd>
                {transcriptionUnavailable
                  ? "unavailable"
                  : transcription
                    ? statusLabel(transcription.status)
                    : "not queued"}
              </dd>
            </div>
          </dl>

          <section className="transcript-panel" aria-label="Transcription">
            <TranscriptionPanel
              transcription={transcription}
              unavailable={transcriptionUnavailable}
            />
          </section>
        </article>
      </main>
    </div>
  );
}
