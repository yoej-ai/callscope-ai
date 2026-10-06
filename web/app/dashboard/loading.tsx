export default function DashboardLoading() {
  return (
    <main className="status-page" aria-busy="true" aria-live="polite">
      <div className="spinner" aria-hidden="true" />
      <p>Preparing your workspace…</p>
    </main>
  );
}
