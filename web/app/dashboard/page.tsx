import Link from "next/link";
import { redirect } from "next/navigation";

import {
  ApiClientError,
  type ApiErrorKind,
  getApiIdentity,
  getApiWorkspace,
} from "@/lib/api/client";
import { isUuid } from "@/lib/api/types";
import { CallUpload } from "@/components/call-upload";
import { DashboardNav } from "@/components/dashboard-nav";
import {
  PendingUploadRecovery,
  StaleUploadReconciliation,
} from "@/components/upload-recovery";
import { createClient } from "@/lib/supabase/server";
import { listAccessibleWorkspaces } from "@/lib/workspaces";

type DashboardPageProps = {
  searchParams: Promise<{ workspace?: string | string[] }>;
};

type DashboardApiErrorProps = {
  email: string;
  kind: Exclude<ApiErrorKind, "authentication">;
};

const CALL_STATUSES = new Set([
  "pending_upload",
  "uploaded",
  "processing",
  "completed",
  "failed",
]);

type CallSummary = {
  id: string;
  originalFilename: string;
  contentType: string | null;
  sizeBytes: number | null;
  status: string;
  createdAt: string;
  uploadCompletedAt: string | null;
};

function parseCallSummary(value: unknown): CallSummary | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return null;
  }

  const call = value as Record<string, unknown>;
  if (
    !isUuid(call.id) ||
    typeof call.original_filename !== "string" ||
    !call.original_filename.trim() ||
    (call.content_type !== null && typeof call.content_type !== "string") ||
    (call.size_bytes !== null &&
      (typeof call.size_bytes !== "number" ||
        !Number.isSafeInteger(call.size_bytes) ||
        call.size_bytes < 1)) ||
    typeof call.status !== "string" ||
    !CALL_STATUSES.has(call.status) ||
    typeof call.created_at !== "string" ||
    Number.isNaN(Date.parse(call.created_at)) ||
    (call.upload_completed_at !== null &&
      (typeof call.upload_completed_at !== "string" ||
        Number.isNaN(Date.parse(call.upload_completed_at))))
  ) {
    return null;
  }

  return {
    id: call.id,
    originalFilename: call.original_filename,
    contentType: call.content_type,
    sizeBytes: call.size_bytes,
    status: call.status,
    createdAt: call.created_at,
    uploadCompletedAt: call.upload_completed_at,
  };
}

function formatSize(sizeBytes: number | null) {
  if (sizeBytes === null) return "Size unavailable";
  const sizeMiB = sizeBytes / (1024 * 1024);
  return sizeMiB >= 0.1
    ? `${sizeMiB.toFixed(sizeMiB >= 10 ? 1 : 2)} MiB`
    : `${Math.ceil(sizeBytes / 1024)} KiB`;
}

function formatDate(value: string) {
  return new Intl.DateTimeFormat("en-AU", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}

function statusLabel(status: string) {
  return status.replaceAll("_", " ");
}

function DashboardApiError({ email, kind }: DashboardApiErrorProps) {
  const unavailable = kind === "unavailable";

  return (
    <div className="dashboard-shell">
      <DashboardNav email={email} />
      <main className="dashboard-main">
        <section className="empty-state" role="alert">
          <div className="empty-icon" aria-hidden="true">
            !
          </div>
          <div>
            <h1>
              {unavailable
                ? "The secure workspace service is temporarily unavailable."
                : "We could not securely load this workspace."}
            </h1>
            <p>Please refresh the page and try again.</p>
          </div>
        </section>
      </main>
    </div>
  );
}

export default async function DashboardPage({
  searchParams,
}: DashboardPageProps) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/sign-in?message=Please%20sign%20in%20to%20continue.");
  }

  const { workspaces, error: workspaceError } =
    await listAccessibleWorkspaces(supabase);

  if (workspaceError) {
    console.error("Unable to load dashboard workspaces", {
      code: workspaceError.code,
    });

    return (
      <div className="dashboard-shell">
        <DashboardNav email={user.email ?? "Signed-in user"} />
        <main className="dashboard-main">
          <section className="empty-state" role="alert">
            <div className="empty-icon" aria-hidden="true">
              !
            </div>
            <div>
              <h1>We could not load your workspaces.</h1>
              <p>Please refresh the page and try again.</p>
            </div>
          </section>
        </main>
      </div>
    );
  }

  if (workspaces.length === 0) {
    redirect("/onboarding");
  }

  const { workspace: requestedWorkspace } = await searchParams;
  const requestedWorkspaceId =
    typeof requestedWorkspace === "string" ? requestedWorkspace : undefined;
  const activeWorkspace =
    workspaces.find((workspace) => workspace.id === requestedWorkspaceId) ??
    workspaces[0];

  const {
    data: { session },
    error: sessionError,
  } = await supabase.auth.getSession();

  if (sessionError || !session?.access_token) {
    redirect(
      "/sign-in?message=Your%20session%20could%20not%20be%20verified.%20Please%20sign%20in%20again.",
    );
  }

  let apiIdentity;
  try {
    apiIdentity = await getApiIdentity(session.access_token);
  } catch (error) {
    if (error instanceof ApiClientError) {
      if (error.kind === "authentication") {
        redirect(
          "/sign-in?message=Your%20session%20could%20not%20be%20verified.%20Please%20sign%20in%20again.",
        );
      }

      console.error("Secure API identity verification failed", {
        kind: error.kind,
        status: error.status,
      });
      return (
        <DashboardApiError
          email={user.email ?? "Signed-in user"}
          kind={error.kind}
        />
      );
    }

    console.error("Secure API identity verification failed unexpectedly");
    return (
      <DashboardApiError
        email={user.email ?? "Signed-in user"}
        kind="invalid-response"
      />
    );
  }

  if (apiIdentity.user_id !== user.id) {
    console.error("Secure API identity did not match the trusted user");
    return (
      <DashboardApiError
        email={user.email ?? "Signed-in user"}
        kind="invalid-response"
      />
    );
  }

  let apiWorkspace;
  try {
    apiWorkspace = await getApiWorkspace(
      session.access_token,
      activeWorkspace.id,
    );
  } catch (error) {
    if (error instanceof ApiClientError) {
      if (error.kind === "authentication") {
        redirect(
          "/sign-in?message=Your%20session%20could%20not%20be%20verified.%20Please%20sign%20in%20again.",
        );
      }

      console.error("Secure workspace lookup failed", {
        kind: error.kind,
        status: error.status,
        workspaceId: activeWorkspace.id,
      });
      return (
        <DashboardApiError
          email={user.email ?? "Signed-in user"}
          kind={error.kind}
        />
      );
    }

    console.error("Secure workspace lookup failed unexpectedly", {
      workspaceId: activeWorkspace.id,
    });
    return (
      <DashboardApiError
        email={user.email ?? "Signed-in user"}
        kind="invalid-response"
      />
    );
  }

  if (apiWorkspace.id !== activeWorkspace.id) {
    console.error("Secure API workspace did not match the requested workspace");
    return (
      <DashboardApiError
        email={user.email ?? "Signed-in user"}
        kind="invalid-response"
      />
    );
  }

  const { data: callRows, error: callError } = await supabase
    .from("calls")
    .select(
      "id, original_filename, content_type, size_bytes, status, created_at, upload_completed_at",
    )
    .eq("workspace_id", activeWorkspace.id)
    .order("created_at", { ascending: false })
    .limit(25);

  const parsedCalls = (callRows ?? []).map(parseCallSummary);
  const callsAreValid = parsedCalls.every(
    (call): call is CallSummary => call !== null,
  );
  const calls = callsAreValid ? parsedCalls : [];
  const callListFailed = Boolean(callError) || !callsAreValid;

  if (callError) {
    console.error("Unable to load workspace calls", { code: callError.code });
  } else if (!callsAreValid) {
    console.error("Workspace call response was invalid");
  }

  return (
    <div className="dashboard-shell">
      <DashboardNav email={user.email ?? "Signed-in user"} />
      <main className="dashboard-main">
        <section className="workspace-header" aria-labelledby="workspace-title">
          <div>
            <p className="eyebrow">Active workspace</p>
            <h1 id="workspace-title">{apiWorkspace.name}</h1>
          </div>
          <form action="/dashboard" className="workspace-switcher" method="get">
            <label htmlFor="workspace">Switch workspace</label>
            <div>
              <select
                className="workspace-select"
                defaultValue={activeWorkspace.id}
                id="workspace"
                name="workspace"
              >
                {workspaces.map((workspace) => (
                  <option key={workspace.id} value={workspace.id}>
                    {workspace.name}
                  </option>
                ))}
              </select>
              <button className="button secondary small" type="submit">
                Open
              </button>
            </div>
          </form>
        </section>
        <p className="lede">
          Securely upload call recordings for transcription, AI analysis, and
          structured insights.
        </p>
        <div className="dashboard-content">
          <CallUpload workspaceId={activeWorkspace.id} />
          <section className="call-history" aria-labelledby="call-history-title">
            <div className="section-heading">
              <div>
                <p className="eyebrow">Recent activity</p>
                <h2 id="call-history-title">Call history</h2>
              </div>
              <div className="history-actions">
                {!callListFailed && calls.length > 0 && (
                  <span className="call-count">Latest {calls.length}</span>
                )}
                <StaleUploadReconciliation workspaceId={activeWorkspace.id} />
              </div>
            </div>

            {callListFailed ? (
              <div className="call-list-message error" role="alert">
                <strong>Call history could not be loaded.</strong>
                <span>Please refresh the page and try again.</span>
              </div>
            ) : calls.length === 0 ? (
              <div className="call-list-message">
                <strong>No calls yet</strong>
                <span>Upload the first recording for this workspace.</span>
              </div>
            ) : (
              <ol className="call-list">
                {calls.map((call) => (
                  <li key={call.id} className="call-row">
                    <div className="call-primary">
                      <Link
                        className="call-link"
                        href={`/dashboard/calls/${encodeURIComponent(call.id)}`}
                      >
                        {call.originalFilename}
                      </Link>
                      <span>
                        {formatSize(call.sizeBytes)}
                        {call.contentType ? ` · ${call.contentType}` : ""}
                      </span>
                    </div>
                    <div className="call-secondary">
                      <span className={`call-status ${call.status}`}>
                        {statusLabel(call.status)}
                      </span>
                      <time dateTime={call.uploadCompletedAt ?? call.createdAt}>
                        {formatDate(call.uploadCompletedAt ?? call.createdAt)}
                      </time>
                      {call.status === "pending_upload" && (
                        <PendingUploadRecovery
                          callId={call.id}
                          workspaceId={activeWorkspace.id}
                        />
                      )}
                    </div>
                  </li>
                ))}
              </ol>
            )}
          </section>
        </div>
      </main>
    </div>
  );
}

