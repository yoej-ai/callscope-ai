import Link from "next/link";

const outcomes = [
  ["Know the moment", "Surface intent, sentiment, and objections without replaying every call."],
  ["Coach with context", "Give sales and support teams a shared, searchable record of customer reality."],
  ["Act consistently", "Turn summaries and action items into a dependable follow-up workflow."],
];

export default function Home() {
  return (
    <main>
      <header className="site-header">
        <Link className="brand" href="/">
          CallScope AI
        </Link>
        <nav aria-label="Primary navigation">
          <Link className="text-link" href="/sign-in">
            Sign in
          </Link>
          <Link className="button primary small" href="/sign-up">
            Get started
          </Link>
        </nav>
      </header>

      <section className="hero">
        <div className="hero-copy">
          <p className="eyebrow">Conversation intelligence, made useful</p>
          <h1>Hear what your customers are really telling you.</h1>
          <p className="lede">
            CallScope AI helps revenue and support teams turn every customer
            conversation into clear signals, decisions, and follow-through.
          </p>
          <div className="hero-actions">
            <Link className="button primary" href="/sign-up">
              Create your workspace
            </Link>
            <Link className="button secondary" href="/sign-in">
              Sign in
            </Link>
          </div>
          <p className="trust-line">Secure multi-tenant foundation · Human-readable insights · Built for teams</p>
        </div>

        <aside className="signal-card" aria-label="Example call insights">
          <div className="signal-card-header">
            <div>
              <span className="status-dot" /> Completed call
            </div>
            <span aria-label="Call duration: 18 minutes 42 seconds">
              18m 42s
            </span>
          </div>
          <p className="signal-label">Customer intent</p>
          <h2>Evaluating for a 25-seat rollout</h2>
          <div className="signal-grid">
            <div>
              <span>Sentiment</span>
              <strong>Positive</strong>
            </div>
            <div>
              <span>Opportunity score</span>
              <strong>86 / 100</strong>
            </div>
          </div>
          <div className="signal-note">
            <span>Key objection</span>
            <p>Needs clarity on onboarding effort and CRM compatibility.</p>
          </div>
        </aside>
      </section>

      <section className="outcomes" aria-labelledby="outcomes-title">
        <p className="eyebrow">From conversation to action</p>
        <h2 id="outcomes-title">A cleaner operating rhythm for customer-facing teams.</h2>
        <div className="outcome-grid">
          {outcomes.map(([title, body], index) => (
            <article key={title}>
              <span>0{index + 1}</span>
              <h3>{title}</h3>
              <p>{body}</p>
            </article>
          ))}
        </div>
      </section>
    </main>
  );
}
