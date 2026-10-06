import Link from "next/link";

export default function NotFound() {
  return (
    <main className="status-page">
      <p className="eyebrow">404</p>
      <h1>That page isn’t in scope.</h1>
      <p className="muted">The address may be incorrect or the page may have moved.</p>
      <Link className="button primary" href="/">
        Return home
      </Link>
    </main>
  );
}
