import { redirect } from "next/navigation";

import { DashboardNav } from "@/components/dashboard-nav";
import { createClient } from "@/lib/supabase/server";

export default async function DashboardPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/sign-in?message=Please%20sign%20in%20to%20continue.");
  }

  return (
    <div className="dashboard-shell">
      <DashboardNav email={user.email ?? "Signed-in user"} />
      <main className="dashboard-main">
        <p className="eyebrow">V1 foundation</p>
        <h1>Your call intelligence workspace</h1>
        <p className="lede">
          Authentication is ready. Workspace creation, call ingestion, and AI
          analysis will be connected in the next development phase.
        </p>
        <section className="empty-state" aria-labelledby="empty-title">
          <div className="empty-icon" aria-hidden="true">
            ◌
          </div>
          <div>
            <h2 id="empty-title">No calls yet</h2>
            <p>
              This secure dashboard is intentionally focused on the SaaS
              foundation. Audio upload is not enabled yet.
            </p>
          </div>
        </section>
      </main>
    </div>
  );
}
