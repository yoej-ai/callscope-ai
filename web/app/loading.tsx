export default function Loading() {
  return (
    <main className="status-page" aria-busy="true" aria-live="polite">
      <div className="spinner" aria-hidden="true" />
      <p>Loading CallScope AI…</p>
    </main>
  );
}
