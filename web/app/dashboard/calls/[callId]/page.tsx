import Link from "next/link";
import { notFound, redirect } from "next/navigation";

import { CallStatusAutoRefresh } from "@/components/call-status-auto-refresh";
import { DashboardNav } from "@/components/dashboard-nav";
import { isUuid } from "@/lib/api/types";
import { humanizeDisplayLabel } from "@/lib/presentation/labels.mjs";
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

const ANALYSIS_STATUSES = new Set([
  "queued",
  "processing",
  "completed",
  "failed",
]);

const SENTIMENTS = new Set([
  "positive",
  "neutral",
  "negative",
  "mixed",
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

type AnalysisDetail = {
  status: "queued" | "processing" | "completed" | "failed";
  summary: string | null;
  sentiment: "positive" | "neutral" | "negative" | "mixed" | null;
  primaryIntent: string | null;
  objections: string[];
  actionItems: string[];
  topics: string[];
  overallScore: number | null;
  startedAt: string | null;
  completedAt: string | null;
};

type ProcessingStage = {
  label: string;
  tone: "queued" | "processing" | "completed" | "failed";
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isTimestamp(value: unknown): value is string {
  return typeof value === "string" && !Number.isNaN(Date.parse(value));
}

function parseCallDetail(
  value: unknown,
  callId: string,
): CallDetail | null {
  if (!isRecord(value)) return null;

  if (
    value.id !== callId ||
    !isUuid(value.workspace_id) ||
    typeof value.original_filename !== "string" ||
    !value.original_filename.trim() ||
    typeof value.status !== "string" ||
    !CALL_STATUSES.has(value.status) ||
    (
      value.duration_seconds !== null &&
      (
        typeof value.duration_seconds !== "number" ||
        !Number.isSafeInteger(value.duration_seconds) ||
        value.duration_seconds < 0
      )
    ) ||
    !isTimestamp(value.created_at) ||
    (
      value.upload_completed_at !== null &&
      !isTimestamp(value.upload_completed_at)
    )
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

function parseTranscriptionDetail(
  value: unknown,
): TranscriptionDetail | null {
  if (!isRecord(value)) return null;

  if (
    typeof value.status !== "string" ||
    !TRANSCRIPTION_STATUSES.has(value.status) ||
    (
      value.transcript_text !== null &&
      typeof value.transcript_text !== "string"
    ) ||
    (
      value.language_code !== null &&
      typeof value.language_code !== "string"
    ) ||
    (
      value.started_at !== null &&
      !isTimestamp(value.started_at)
    ) ||
    (
      value.completed_at !== null &&
      !isTimestamp(value.completed_at)
    )
  ) {
    return null;
  }

  if (
    value.status === "completed" &&
    (
      typeof value.transcript_text !== "string" ||
      !value.transcript_text.trim() ||
      !isTimestamp(value.completed_at)
    )
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

function parseStringArray(
  value: unknown,
  maximumElements: number,
  maximumItemCharacters: number,
) {
  if (
    !Array.isArray(value) ||
    value.length > maximumElements ||
    value.some(
      (item) =>
        typeof item !== "string" ||
        !item.trim() ||
        item.length > maximumItemCharacters,
    )
  ) {
    return null;
  }

  return value as string[];
}

function parseAnalysisDetail(
  value: unknown,
): AnalysisDetail | null {
  if (!isRecord(value)) return null;

  const objections = parseStringArray(
    value.objections,
    25,
    1000,
  );

  const actionItems = parseStringArray(
    value.action_items,
    50,
    1000,
  );

  const topics = parseStringArray(
    value.topics,
    50,
    200,
  );

  if (
    typeof value.status !== "string" ||
    !ANALYSIS_STATUSES.has(value.status) ||
    (
      value.summary !== null &&
      typeof value.summary !== "string"
    ) ||
    (
      value.sentiment !== null &&
      (
        typeof value.sentiment !== "string" ||
        !SENTIMENTS.has(value.sentiment)
      )
    ) ||
    (
      value.primary_intent !== null &&
      typeof value.primary_intent !== "string"
    ) ||
    objections === null ||
    actionItems === null ||
    topics === null ||
    (
      value.overall_score !== null &&
      (
        typeof value.overall_score !== "number" ||
        !Number.isSafeInteger(value.overall_score) ||
        value.overall_score < 0 ||
        value.overall_score > 100
      )
    ) ||
    (
      value.started_at !== null &&
      !isTimestamp(value.started_at)
    ) ||
    (
      value.completed_at !== null &&
      !isTimestamp(value.completed_at)
    )
  ) {
    return null;
  }

  if (
    value.status === "completed" &&
    (
      typeof value.summary !== "string" ||
      !value.summary.trim() ||
      value.summary.length > 10000 ||
      typeof value.primary_intent !== "string" ||
      !value.primary_intent.trim() ||
      value.primary_intent.length > 500 ||
      typeof value.sentiment !== "string" ||
      !SENTIMENTS.has(value.sentiment) ||
      !isTimestamp(value.completed_at)
    )
  ) {
    return null;
  }

  if (
    value.status !== "completed" &&
    (
      value.summary !== null ||
      value.sentiment !== null ||
      value.primary_intent !== null ||
      objections.length > 0 ||
      actionItems.length > 0 ||
      topics.length > 0 ||
      value.overall_score !== null ||
      value.completed_at !== null
    )
  ) {
    return null;
  }

  return {
    status: value.status as AnalysisDetail["status"],
    summary: value.summary,
    sentiment: value.sentiment as AnalysisDetail["sentiment"],
    primaryIntent: value.primary_intent,
    objections,
    actionItems,
    topics,
    overallScore: value.overall_score,
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

function formatDuration(
  durationSeconds: number | null,
) {
  if (durationSeconds === null) return "Not available";

  const minutes = Math.floor(durationSeconds / 60);
  const seconds = durationSeconds % 60;

  return minutes > 0
    ? `${minutes}m ${seconds}s`
    : `${seconds}s`;
}

function uploadStatusLabel(status: string) {
  const labels: Record<string, string> = {
    pending_upload: "Upload pending",
    uploaded: "Upload complete",
    processing: "Upload processing",
    completed: "Upload complete",
    failed: "Upload failed",
  };

  return labels[status] ?? "Upload status unavailable";
}

function processingStage(
  call: CallDetail,
  transcription: TranscriptionDetail | null,
  transcriptionUnavailable: boolean,
  analysis: AnalysisDetail | null,
  analysisUnavailable: boolean,
): ProcessingStage {
  if (call.status === "pending_upload") {
    return { label: "Uploading", tone: "processing" };
  }

  if (call.status === "failed") {
    return { label: "Upload failed", tone: "failed" };
  }

  if (transcriptionUnavailable) {
    return { label: "Status unavailable", tone: "failed" };
  }

  if (!transcription || transcription.status === "queued") {
    return { label: "Waiting for transcription", tone: "queued" };
  }

  if (transcription.status === "processing") {
    return { label: "Transcribing", tone: "processing" };
  }

  if (transcription.status === "failed") {
    return { label: "Transcription failed", tone: "failed" };
  }

  if (analysisUnavailable) {
    return { label: "Analysis status unavailable", tone: "failed" };
  }

  if (!analysis || analysis.status === "queued") {
    return { label: "Waiting for AI analysis", tone: "queued" };
  }

  if (analysis.status === "processing") {
    return { label: "Analyzing", tone: "processing" };
  }

  if (analysis.status === "failed") {
    return { label: "Analysis failed", tone: "failed" };
  }

  return { label: "Completed", tone: "completed" };
}

function ActiveProcessingState({
  eyebrow,
  title,
  description,
  tone,
}: {
  eyebrow: string;
  title: string;
  description: string;
  tone: "queued" | "processing";
}) {
  return (
    <div
      aria-live="polite"
      className={`processing-state ${tone}`}
      role="status"
    >
      <p className="eyebrow">{eyebrow}</p>
      <div className="processing-state-status">
        <span className="activity-indicator" aria-hidden="true" />
        <span className={`call-status ${tone}`}>
          {tone === "queued" ? "Queued" : "Processing"}
        </span>
      </div>
      <h2>{title}</h2>
      <p>{description}</p>
      <p className="processing-note">This page updates automatically.</p>
    </div>
  );
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
      <div
        className="transcript-state"
        role="alert"
      >
        <h2>Transcript unavailable</h2>
        <p>
          We could not securely load the transcription state.
          Try again later.
        </p>
      </div>
    );
  }

  if (!transcription) {
    return (
      <div className="transcript-state">
        <h2>Waiting for transcription</h2>
        <p>
          The upload is complete, but transcription has not been queued yet.
          Keep the local CallScope worker running.
        </p>
      </div>
    );
  }

  if (transcription.status === "queued") {
    return (
      <ActiveProcessingState
        description="Your recording is queued and will begin when the local worker is available."
        eyebrow="Transcript"
        title="Waiting for transcription..."
        tone="queued"
      />
    );
  }

  if (transcription.status === "processing") {
    return (
      <ActiveProcessingState
        description="The local worker is turning this recording into a transcript."
        eyebrow="Transcript"
        title="Transcribing recording..."
        tone="processing"
      />
    );
  }

  if (transcription.status === "failed") {
    return (
      <div
        className="transcript-state"
        role="status"
      >
        <h2>Transcription failed</h2>
        <p>
          Processing failed. Check the local worker and recording, then try
          again when processing is available. Manual retry is not available
          in the browser.
        </p>
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

        <span className="call-count">
          {transcription.languageCode
            ? `Language: ${transcription.languageCode}`
            : "Language not confidently detected"}
        </span>
      </div>

      <p className="transcript-text">
        {transcription.transcriptText}
      </p>

      {transcription.completedAt && (
        <p className="transcript-timestamp">
          Completed {formatDate(transcription.completedAt)}
        </p>
      )}
    </div>
  );
}

function InsightList({
  items,
  emptyLabel,
}: {
  items: string[];
  emptyLabel: string;
}) {
  if (items.length === 0) {
    return (
      <p className="insight-empty">
        {emptyLabel}
      </p>
    );
  }

  return (
    <ul className="insight-list">
      {items.map((item, index) => (
        <li key={`${index}-${item}`}>
          {humanizeDisplayLabel(item)}
        </li>
      ))}
    </ul>
  );
}

function AnalysisPanel({
  analysis,
  unavailable,
  transcriptionStatus,
}: {
  analysis: AnalysisDetail | null;
  unavailable: boolean;
  transcriptionStatus: TranscriptionDetail["status"] | null;
}) {
  if (unavailable) {
    return (
      <div
        className="insights-state"
        role="alert"
      >
        <p className="eyebrow">
          AI Insights
        </p>

        <h2>Insights unavailable</h2>

        <p>
          We could not securely load the analysis state.
          Try again later.
        </p>
      </div>
    );
  }

  if (!analysis) {
    const transcriptCompleted = transcriptionStatus === "completed";

    return (
      <div className="insights-state">
        <p className="eyebrow">
          AI Insights
        </p>

        <h2>
          {transcriptCompleted
            ? "Waiting for AI analysis"
            : "Waiting for transcript"}
        </h2>

        <p>
          {transcriptCompleted
            ? "The transcript is ready, but analysis has not been queued yet. Keep the local CallScope worker and Ollama running."
            : "AI analysis begins only after transcription completes successfully."}
        </p>
      </div>
    );
  }

  if (analysis.status === "queued") {
    return (
      <ActiveProcessingState
        description="The transcript is ready and waiting for the local analysis service."
        eyebrow="AI Insights"
        title="Queued for AI analysis..."
        tone="queued"
      />
    );
  }

  if (analysis.status === "processing") {
    return (
      <ActiveProcessingState
        description="The local analysis service is turning the transcript into structured insights."
        eyebrow="AI Insights"
        title="Analyzing conversation..."
        tone="processing"
      />
    );
  }

  if (analysis.status === "failed") {
    return (
      <div
        className="insights-state"
        role="status"
      >
        <p className="eyebrow">
          AI Insights
        </p>

        <h2>Analysis failed</h2>

        <p>
          The transcript remains available, but processing failed. Check the
          local worker and try again when processing is available. Manual retry
          is not available in the browser.
        </p>
      </div>
    );
  }

  return (
    <div className="insights-result">
      <div className="section-heading insights-heading">
        <div>
          <p className="eyebrow">
            AI Insights
          </p>

          <h2>
            Completed analysis
          </h2>
        </div>

        {analysis.overallScore !== null && (
          <div
            className="insight-score"
          >
            <span>Opportunity score</span>
            <strong>{analysis.overallScore} <small>/ 100</small></strong>
          </div>
        )}
      </div>

      <div className="insight-summary">
        <h3>Summary</h3>
        <p>{analysis.summary}</p>
      </div>

      <dl className="insight-facts">
        <div>
          <dt>Sentiment</dt>
          <dd className={`sentiment-value ${analysis.sentiment}`}>
            {analysis.sentiment
              ? humanizeDisplayLabel(analysis.sentiment)
              : "Not identified"}
          </dd>
        </div>

        <div>
          <dt>Primary intent</dt>
          <dd>
            {analysis.primaryIntent
              ? humanizeDisplayLabel(analysis.primaryIntent)
              : "Not identified"}
          </dd>
        </div>
      </dl>

      <div className="insight-grid">
        <section
          aria-labelledby="insight-objections"
        >
          <h3 id="insight-objections">
            Objections
          </h3>

          <InsightList
            items={analysis.objections}
            emptyLabel="No objections identified."
          />
        </section>

        <section
          aria-labelledby="insight-actions"
        >
          <h3 id="insight-actions">
            Action items
          </h3>

          <InsightList
            items={analysis.actionItems}
            emptyLabel="No action items identified."
          />
        </section>

        <section
          aria-labelledby="insight-topics"
        >
          <h3 id="insight-topics">
            Topics
          </h3>

          <InsightList
            items={analysis.topics}
            emptyLabel="No topics identified."
          />
        </section>
      </div>

      {analysis.completedAt && (
        <p className="insights-timestamp">
          Completed {formatDate(analysis.completedAt)}
        </p>
      )}
    </div>
  );
}

export default async function CallDetailPage({
  params,
}: CallDetailPageProps) {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect(
      "/sign-in?message=Please%20sign%20in%20to%20continue.",
    );
  }

  const { callId } = await params;

  if (!isUuid(callId)) {
    notFound();
  }

  const {
    data: callRow,
    error: callError,
  } = await supabase
    .from("calls")
    .select(
      "id, workspace_id, original_filename, status, duration_seconds, created_at, upload_completed_at",
    )
    .eq("id", callId)
    .maybeSingle();

  const call = parseCallDetail(
    callRow,
    callId,
  );

  if (
    callError ||
    !call
  ) {
    notFound();
  }

  const {
    data: transcriptionRow,
    error: transcriptionError,
  } = await supabase
    .from("call_transcriptions")
    .select(
      "status, transcript_text, language_code, started_at, completed_at",
    )
    .eq("call_id", call.id)
    .maybeSingle();

  const transcription = transcriptionRow
    ? parseTranscriptionDetail(
        transcriptionRow,
      )
    : null;

  const transcriptionUnavailable =
    Boolean(transcriptionError) ||
    Boolean(
      transcriptionRow &&
      !transcription,
    );

  if (transcriptionError) {
    console.error(
      "Unable to load call transcription",
      {
        code: transcriptionError.code,
      },
    );
  } else if (
    transcriptionRow &&
    !transcription
  ) {
    console.error(
      "Call transcription response was invalid",
    );
  }

  const {
    data: analysisRow,
    error: analysisError,
  } = await supabase
    .from("call_analyses")
    .select(
      "status, summary, sentiment, primary_intent, objections, action_items, topics, overall_score, started_at, completed_at",
    )
    .eq("call_id", call.id)
    .maybeSingle();

  const analysis = analysisRow
    ? parseAnalysisDetail(
        analysisRow,
      )
    : null;

  const analysisUnavailable =
    Boolean(analysisError) ||
    Boolean(
      analysisRow &&
      !analysis,
    );

  if (analysisError) {
    console.error(
      "Unable to load call analysis",
      {
        code: analysisError.code,
      },
    );
  } else if (
    analysisRow &&
    !analysis
  ) {
    console.error(
      "Call analysis response was invalid",
    );
  }

  const shouldRefreshCallStatus =
    (
      !transcriptionUnavailable &&
      (
        transcription?.status === "queued" ||
        transcription?.status === "processing"
      )
    ) ||
    (
      !analysisUnavailable &&
      (
        analysis?.status === "queued" ||
        analysis?.status === "processing"
      )
    );

  const currentStage = processingStage(
    call,
    transcription,
    transcriptionUnavailable,
    analysis,
    analysisUnavailable,
  );

  return (
    <>
      <CallStatusAutoRefresh
        active={shouldRefreshCallStatus}
      />

      <div className="dashboard-shell">
        <DashboardNav
          email={
            user.email ??
            "Signed-in user"
          }
        />

        <main className="dashboard-main call-detail-main">
          <Link
            className="text-link back-link"
            href={
              `/dashboard?workspace=${encodeURIComponent(
                call.workspaceId,
              )}`
            }
          >
            ← Back to dashboard
          </Link>

          <article
            className="call-detail-card"
            aria-labelledby="call-detail-title"
          >
            <header className="call-detail-header">
              <div className="call-detail-title">
                <p className="eyebrow">
                  Call detail
                </p>

                <h1 id="call-detail-title">
                  {call.originalFilename}
                </h1>
              </div>

              <span
                className={
                  `call-status ${currentStage.tone}`
                }
              >
                {currentStage.label}
              </span>
            </header>

            <dl className="call-metadata">
              <div>
                <dt>Upload state</dt>
                <dd>
                  {uploadStatusLabel(call.status)}
                </dd>
              </div>

              <div>
                <dt>Duration</dt>
                <dd>
                  {formatDuration(
                    call.durationSeconds,
                  )}
                </dd>
              </div>

              <div>
                <dt>Added</dt>
                <dd>
                  {formatDate(
                    call.uploadCompletedAt ??
                    call.createdAt,
                  )}
                </dd>
              </div>
            </dl>

            <section
              className="transcript-panel"
              aria-label="Transcription"
            >
              <TranscriptionPanel
                transcription={
                  transcription
                }
                unavailable={
                  transcriptionUnavailable
                }
              />
            </section>

            <section
              className="insights-panel"
              aria-label="AI Insights"
            >
              <AnalysisPanel
                analysis={analysis}
                unavailable={
                  analysisUnavailable
                }
                transcriptionStatus={
                  transcription?.status ?? null
                }
              />
            </section>
          </article>
        </main>
      </div>
    </>
  );
}
