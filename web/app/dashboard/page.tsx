import Link from "next/link";
import { redirect } from "next/navigation";

import {
  ApiClientError,
  type ApiErrorKind,
  getApiIdentity,
  getApiWorkspace,
} from "@/lib/api/client";
import {
  callHistoryStageLabel,
  dashboardCallHistoryHref,
  isActiveCallHistoryStage,
  normalizeCallSearch,
  parseCallHistoryPage,
  parseCallHistoryResponse,
  parseCallHistorySort,
  parseCallHistoryStatus,
} from "@/lib/call-history.mjs";
import { callDisplayName, canManageCall } from "@/lib/call-management.mjs";
import { CallActions } from "@/components/call-actions";
import { CallStatusAutoRefresh } from "@/components/call-status-auto-refresh";
import { CallUpload } from "@/components/call-upload";
import { DashboardNav } from "@/components/dashboard-nav";
import {
  PendingUploadRecovery,
  StaleUploadReconciliation,
} from "@/components/upload-recovery";
import { createClient } from "@/lib/supabase/server";
import { listAccessibleWorkspaces } from "@/lib/workspaces";

type DashboardPageProps = {
  searchParams: Promise<{
    workspace?: string | string[];
    q?: string | string[];
    status?: string | string[];
    sort?: string | string[];
    page?: string | string[];
  }>;
};

type DashboardApiErrorProps = {
  email: string;
  kind: Exclude<ApiErrorKind, "authentication">;
};

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

  const {
    workspace: requestedWorkspace,
    q: requestedSearch,
    status: requestedStatus,
    sort: requestedSort,
    page: requestedPage,
  } = await searchParams;
  const requestedWorkspaceId =
    typeof requestedWorkspace === "string" ? requestedWorkspace : undefined;
  const activeWorkspace =
    workspaces.find((workspace) => workspace.id === requestedWorkspaceId) ??
    workspaces[0];
  const search = normalizeCallSearch(
    typeof requestedSearch === "string" ? requestedSearch : "",
  );
  const statusFilter = parseCallHistoryStatus(
    typeof requestedStatus === "string" ? requestedStatus : undefined,
  );
  const sortOrder = parseCallHistorySort(
    typeof requestedSort === "string" ? requestedSort : undefined,
  );
  const requestedPageNumber = parseCallHistoryPage(
    typeof requestedPage === "string" ? requestedPage : undefined,
  );

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

  const { data: activeMembership, error: membershipError } = await supabase
    .from("workspace_members")
    .select("role")
    .eq("workspace_id", activeWorkspace.id)
    .eq("user_id", user.id)
    .maybeSingle();
  const workspaceRole =
    activeMembership?.role === "owner" ||
    activeMembership?.role === "admin" ||
    activeMembership?.role === "member"
      ? activeMembership.role
      : null;

  if (membershipError) {
    console.error("Unable to load active workspace membership", {
      code: membershipError.code,
      workspaceId: activeWorkspace.id,
    });
  }

  let callHistory: ReturnType<typeof parseCallHistoryResponse> = null;
  let callListFailed = false;

  if (!search.error) {
    const { data: callHistoryValue, error: callHistoryError } = await supabase.rpc(
      "list_workspace_calls",
      {
        p_workspace_id: activeWorkspace.id,
        p_search: search.value || null,
        p_status: statusFilter,
        p_sort: sortOrder,
        p_page: requestedPageNumber,
      },
    );
    callHistory = parseCallHistoryResponse(callHistoryValue);
    callListFailed = Boolean(callHistoryError) || callHistory === null;

    if (callHistoryError) {
      console.error("Unable to load workspace call history", {
        code: callHistoryError.code,
        workspaceId: activeWorkspace.id,
      });
    } else if (!callHistory) {
      console.error("Workspace call history response was invalid");
    }
  }

  if (callHistory && callHistory.page !== requestedPageNumber) {
    redirect(
      dashboardCallHistoryHref({
        workspaceId: activeWorkspace.id,
        search: search.value,
        status: statusFilter,
        sort: sortOrder,
        page: callHistory.page,
      }),
    );
  }

  const calls = callHistory?.items ?? [];
  const hasActiveCalls = calls.some((call) =>
    isActiveCallHistoryStage(call.processingStage),
  );
  const hasDiscoveryFilters = search.value !== "" || statusFilter !== "all";
  const clearFiltersHref = dashboardCallHistoryHref({
    workspaceId: activeWorkspace.id,
  });

  return (
    <div className="dashboard-shell">
      <DashboardNav email={user.email ?? "Signed-in user"} />
      <CallStatusAutoRefresh
        active={!callListFailed && !search.error && hasActiveCalls}
      />
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
                <p className="section-support">
                  Find a call and review its transcript and insights.
                </p>
              </div>
              <div className="history-actions">
                {!callListFailed && callHistory && callHistory.totalCount > 0 && (
                  <span className="call-count">
                    {callHistory.totalCount} {callHistory.totalCount === 1 ? "call" : "calls"}
                  </span>
                )}
                <StaleUploadReconciliation workspaceId={activeWorkspace.id} />
              </div>
            </div>

            <form action="/dashboard" className="history-filters" method="get">
              <input name="workspace" type="hidden" value={activeWorkspace.id} />
              <div className="history-filter-field history-search-field">
                <label htmlFor="call-search">Search calls</label>
                <input
                  defaultValue={search.value}
                  id="call-search"
                  maxLength={100}
                  name="q"
                  placeholder="Name or source filename"
                  type="search"
                />
              </div>
              <div className="history-filter-field">
                <label htmlFor="call-status-filter">Status</label>
                <select
                  defaultValue={statusFilter}
                  id="call-status-filter"
                  name="status"
                >
                  <option value="all">All statuses</option>
                  <option value="in_progress">In progress</option>
                  <option value="completed">Completed</option>
                  <option value="failed">Failed</option>
                  <option value="deleting">Deleting</option>
                </select>
              </div>
              <div className="history-filter-field">
                <label htmlFor="call-sort">Sort</label>
                <select defaultValue={sortOrder} id="call-sort" name="sort">
                  <option value="newest">Newest first</option>
                  <option value="oldest">Oldest first</option>
                </select>
              </div>
              <div className="history-filter-actions">
                <button className="button primary small" type="submit">
                  Apply
                </button>
                <Link className="button ghost small" href={clearFiltersHref}>
                  Clear
                </Link>
              </div>
            </form>

            {search.error ? (
              <div className="call-list-message error" role="alert">
                <strong>Search could not be applied.</strong>
                <span>{search.error}</span>
                <Link className="text-link" href={clearFiltersHref}>
                  Clear filters
                </Link>
              </div>
            ) : callListFailed ? (
              <div className="call-list-message error" role="alert">
                <strong>Call history could not be loaded.</strong>
                <span>Please refresh the page and try again.</span>
              </div>
            ) : callHistory?.workspaceTotalCount === 0 ? (
              <div className="call-list-message">
                <strong>No calls yet</strong>
                <span>Upload the first recording for this workspace.</span>
              </div>
            ) : calls.length === 0 ? (
              <div className="call-list-message">
                <strong>No matching calls</strong>
                <span>Try adjusting your search or filters.</span>
                {hasDiscoveryFilters && (
                  <Link className="text-link" href={clearFiltersHref}>
                    Clear filters
                  </Link>
                )}
              </div>
            ) : (
              <>
                <ol className="call-list">
                  {calls.map((call) => {
                    const displayName = callDisplayName(
                      call.displayName,
                      call.originalFilename,
                    );
                    const viewHref = `/dashboard/calls/${encodeURIComponent(call.id)}`;
                    const manageable = canManageCall({
                      currentUserId: user.id,
                      uploadedBy: call.uploadedBy,
                      workspaceRole,
                    });

                    return (
                      <li key={call.id} className="call-row">
                        <div className="call-primary">
                          <Link className="call-link" href={viewHref}>
                            {displayName}
                          </Link>
                          {call.displayName && (
                            <span>Source: {call.originalFilename}</span>
                          )}
                          <span>
                            {formatSize(call.sizeBytes)}
                            {call.contentType ? ` · ${call.contentType}` : ""}
                          </span>
                        </div>
                        <div className="call-secondary">
                          <div className="call-row-controls">
                            <span className={`call-status ${call.processingStage}`}>
                              {callHistoryStageLabel(call.processingStage)}
                            </span>
                            <CallActions
                              callId={call.id}
                              canManage={manageable}
                              displayName={displayName}
                              isDeleting={call.processingStage === "deleting"}
                              originalFilename={call.originalFilename}
                              retryStage={null}
                              viewHref={viewHref}
                              workspaceId={activeWorkspace.id}
                            />
                          </div>
                          <time dateTime={call.uploadCompletedAt ?? call.createdAt}>
                            {formatDate(call.uploadCompletedAt ?? call.createdAt)}
                          </time>
                          {call.processingStage === "upload_pending" && (
                            <PendingUploadRecovery
                              callId={call.id}
                              workspaceId={activeWorkspace.id}
                            />
                          )}
                        </div>
                      </li>
                    );
                  })}
                </ol>

                {callHistory && callHistory.totalPages > 0 && (
                  <nav className="call-pagination" aria-label="Call history pages">
                    {callHistory.page > 1 ? (
                      <Link
                        className="button ghost small"
                        href={dashboardCallHistoryHref({
                          workspaceId: activeWorkspace.id,
                          search: search.value,
                          status: statusFilter,
                          sort: sortOrder,
                          page: callHistory.page - 1,
                        })}
                      >
                        Previous
                      </Link>
                    ) : (
                      <span aria-disabled="true" className="button ghost small">
                        Previous
                      </span>
                    )}
                    <span className="pagination-position" aria-live="polite">
                      Page {callHistory.page} of {callHistory.totalPages}
                    </span>
                    {callHistory.page < callHistory.totalPages ? (
                      <Link
                        className="button ghost small"
                        href={dashboardCallHistoryHref({
                          workspaceId: activeWorkspace.id,
                          search: search.value,
                          status: statusFilter,
                          sort: sortOrder,
                          page: callHistory.page + 1,
                        })}
                      >
                        Next
                      </Link>
                    ) : (
                      <span aria-disabled="true" className="button ghost small">
                        Next
                      </span>
                    )}
                  </nav>
                )}
              </>
            )}
          </section>
        </div>
      </main>
    </div>
  );
}

