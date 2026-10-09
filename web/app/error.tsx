"use client";

export default function ErrorPage({ reset }: { reset: () => void }) {
  return (
    <main className="status-page">
      <p className="eyebrow">Something went wrong</p>
      <h1>We couldn’t load this page.</h1>
      <p className="muted">Please try again. If the problem continues, wait a moment and retry.</p>
      <button className="button primary" onClick={reset} type="button">
        Try again
      </button>
    </main>
  );
}
