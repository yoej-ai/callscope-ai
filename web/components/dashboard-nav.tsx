import Link from "next/link";

import { signOut } from "@/app/auth/actions";

type DashboardNavProps = {
  email: string;
};

export function DashboardNav({ email }: DashboardNavProps) {
  return (
    <header className="dashboard-nav">
      <Link className="brand" href="/dashboard">
        CallScope AI
      </Link>
      <nav aria-label="Account navigation">
        <Link className="text-link dashboard-home-link" href="/dashboard">
          Dashboard
        </Link>
        <Link className="text-link" href="/dashboard/playbooks">
          Playbooks
        </Link>
        <span>{email}</span>
        <form action={signOut}>
          <button className="button ghost" type="submit">
            Sign out
          </button>
        </form>
      </nav>
    </header>
  );
}
