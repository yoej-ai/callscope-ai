import Link from "next/link";
import { redirect } from "next/navigation";

import { createWorkspace } from "@/app/onboarding/actions";
import { CreateWorkspaceButton } from "@/app/onboarding/submit-button";
import { DashboardNav } from "@/components/dashboard-nav";
import { createClient } from "@/lib/supabase/server";
import { listAccessibleWorkspaces } from "@/lib/workspaces";

const ERROR_MESSAGES = {
  "create-failed": "We could not create your workspace. Please try again.",
  "invalid-name": "Enter a workspace name between 1 and 120 characters.",
} as const;

type OnboardingPageProps = {
  searchParams: Promise<{ error?: string | string[] }>;
};

export default async function OnboardingPage({
  searchParams,
}: OnboardingPageProps) {
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
    console.error("Unable to load onboarding workspaces", {
      code: workspaceError.code,
    });

    return (
      <div className="dashboard-shell">
        <DashboardNav email={user.email ?? "Signed-in user"} />
        <main className="onboarding-main">
          <section className="onboarding-card" role="alert">
            <p className="eyebrow">Workspace setup</p>
            <h1>Workspace setup is temporarily unavailable.</h1>
            <p className="muted">Please try again in a moment.</p>
            <Link className="button secondary" href="/onboarding">
              Try again
            </Link>
          </section>
        </main>
      </div>
    );
  }

  if (workspaces.length > 0) {
    redirect(`/dashboard?workspace=${encodeURIComponent(workspaces[0].id)}`);
  }

  const { error } = await searchParams;
  const errorKey = typeof error === "string" ? error : undefined;
  const message =
    errorKey && Object.hasOwn(ERROR_MESSAGES, errorKey)
      ? ERROR_MESSAGES[errorKey as keyof typeof ERROR_MESSAGES]
      : undefined;

  return (
    <div className="dashboard-shell">
      <DashboardNav email={user.email ?? "Signed-in user"} />
      <main className="onboarding-main">
        <section className="onboarding-card" aria-labelledby="onboarding-title">
          <p className="eyebrow">Workspace setup</p>
          <h1 id="onboarding-title">Create your first workspace</h1>
          <p className="muted">
            Give your team a clear home for call intelligence. You can add calls
            in a later phase.
          </p>

          {message ? (
            <p className="form-message" role="alert">
              {message}
            </p>
          ) : null}

          <form action={createWorkspace} className="auth-form">
            <label htmlFor="workspace-name">Workspace name</label>
            <input
              autoComplete="organization"
              id="workspace-name"
              maxLength={120}
              minLength={1}
              name="name"
              pattern=".*\S.*"
              placeholder="Acme customer success"
              required
              type="text"
            />
            <CreateWorkspaceButton />
          </form>
        </section>
      </main>
    </div>
  );
}

