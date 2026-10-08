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
const ANALYSIS_STATUSES = new Set([
  "queued",
  "processing",
  "completed",
  "failed",
]);
const SENTIMENTS = new Set(["positive", "neutral", "negative", "mixed"]);

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

function parseAnalysisDetail(value: unknown): AnalysisDetail | null {
  if (!isRecord(value)) return null;

  const objections = parseStringArray(value.objections, 25, 1000);
  const actionItems = parseStringArray(value.action_items, 50, 1000);
  const topics = parseStringArray(value.topics, 50, 200);

  if (
    typeof value.status !== "string" ||
    !ANALYSIS_STATUSES.has(value.status) ||
    (value.summary !== null && typeof value.summary !== "string") ||
    (value.sentiment !== null &&
      (typeof value.sentiment !== "string" ||
        !SENTIMENTS.has(value.sentiment))) ||
    (value.primary_intent !== null &&
      typeof value.primary_intent !== "string") ||
    objections === null ||
    actionItems === null ||
    topics === null ||
    (value.overall_score !== null &&
      (typeof value.overall_score !== "number" ||
        !Number.isSafeInteger(value.overall_score) ||
        value.overall_score < 0 ||
        value.overall_score > 100)) ||
    (value.started_at !== null && !isTimestamp(value.started_at)) ||
    (value.completed_at !== null && !isTimestamp(value.completed_at))
  ) {
    return null;
  }

  if (
    value.status === "completed" &&
    (typeof value.summary !== "string" ||
      !value.summary.trim() ||
      value.summary.length > 10000 ||
      typeof value.primary_intent !== "string" ||
      !value.primary_intent.trim() ||
      value.primary_intent.length > 500 ||
      typeof value.sentiment !== "string" ||
      !SENTIMENTS.has(value.sentiment) ||
      !isTimestamp(value.completed_at))
  ) {
    return null;
  }

  if (
    value.status !== "completed" &&
    (value.summary !== null ||
      value.sentiment !== null ||
      value.primary_intent !== null ||
      objections.length > 0 ||
      actionItems.length > 0 ||
      topics.length > 0 ||
      value.overall_score !== null ||
      value.completed_at !== null)
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
        <p>A trusted local worker can process this recording while it is running.</p>
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

function InsightList({
  items,
  emptyLabel,
}: {
  items: string[];
  emptyLabel: string;
}) {
  if (items.length === 0) {
    return <p className="insight-empty">{emptyLabel}</p>;
  }

  return (
    <ul className="insight-list">
      {items.map((item, index) => (
        <li key={`${index}-${item}`}>{item}</li>
      ))}
    </ul>
  );
}

function AnalysisPanel({
  analysis,
  unavailable,
}: {
  analysis: AnalysisDetail | null;
  unavailable: boolean;
}) {
  if (unavailable) {
    return (
      <div className="insights-state" role="alert">
        <p className="eyebrow">AI Insights</p>
        <h2>Insights unavailable</h2>
        <p>We could not securely load the analysis state. Try again later.</p>
      </div>
    );
  }

  if (!analysis) {
    return (
      <div className="insights-state">
        <p className="eyebrow">AI Insights</p>
        <h2>Analysis not queued</h2>
        <p>Analysis waits for a valid completed transcript.</p>
      </div>
    );
  }

  if (analysis.status === "queued") {
    return (
      <div className="insights-state">
        <p className="eyebrow">AI Insights</p>
        <h2>Queued for analysis</h2>
        <p>The secure analysis foundation is ready for a future trusted worker.</p>
      </div>
    );
  }

  if (analysis.status === "processing") {
    return (
      <div className="insights-state" aria-live="polite">
        <p className="eyebrow">AI Insights</p>
        <h2>Analysis in progress</h2>
        <p>A trusted analysis worker currently holds this job.</p>
      </div>
    );
  }

  if (analysis.status === "failed") {
    return (
      <div className="insights-state" role="status">
        <p className="eyebrow">AI Insights</p>
        <h2>Analysis failed</h2>
        <p>The call could not be analysed. Internal worker details remain private.</p>
      </div>
    );
  }

  return (
    <div className="insights-result">
      <div className="section-heading insights-heading">
        <div>
          <p className="eyebrow">AI Insights</p>
          <h2>Completed analysis</h2>
        </div>
        {analysis.overallScore !== null && (
          <span className="insight-score" aria-label={`Overall score ${analysis.overallScore} out of 100`}>
            {analysis.overallScore}/100
          </span>
        )}
      </div>

      <div className="insight-summary">
        <h3>Summary</h3>
        <p>{analysis.summary}</p>
      </div>

      <dl className="insight-facts">
        <div>
          <dt>Sentiment</dt>
          <dd>{analysis.sentiment}</dd>
        </div>
        <div>
          <dt>Primary intent</dt>
          <dd>{analysis.primaryIntent}</dd>
        </div>
      </dl>

      <div className="insight-grid">
        <section aria-labelledby="insight-objections">
          <h3 id="insight-objections">Objections</h3>
          <InsightList items={analysis.objections} emptyLabel="No objections identified." />
        </section>
        <section aria-labelledby="insight-actions">
          <h3 id="insight-actions">Action items</h3>
          <InsightList items={analysis.actionItems} emptyLabel="No action items identified." />
        </section>
        <section aria-labelledby="insight-topics">
          <h3 id="insight-topics">Topics</h3>
          <InsightList items={analysis.topics} emptyLabel="No topics identified." />
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

  const { data: analysisRow, error: analysisError } = await supabase
    .from("call_analyses")
    .select(
      "status, summary, sentiment, primary_intent, objections, action_items, topics, overall_score, started_at, completed_at",
    )
    .eq("call_id", call.id)
    .maybeSingle();

  const analysis = analysisRow ? parseAnalysisDetail(analysisRow) : null;
  const analysisUnavailable =
    Boolean(analysisError) || Boolean(analysisRow && !analysis);

  if (analysisError) {
    console.error("Unable to load call analysis", { code: analysisError.code });
  } else if (analysisRow && !analysis) {
    console.error("Call analysis response was invalid");
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

          <section className="insights-panel" aria-label="AI Insights">
            <AnalysisPanel
              analysis={analysis}
              unavailable={analysisUnavailable}
            />
          </section>
        </article>
      </main>
    </div>
  );
}
