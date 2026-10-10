# Database security tests

The numbered pgTAP suites cover the foundation RLS model, private audio ingestion,
stale upload reconciliation, transcription, the AI-analysis state foundation,
least-privilege call management, and tenant-safe call-history discovery.
Playbook coverage adds owner/admin-only draft management, published-only member
visibility, cross-tenant denial, deterministic concurrency-safe versioning,
publish validation, immutable published history, and restricted RPC grants.
The worker-boundary suites exercise auto-queue and backfill behavior, claims,
wall-clock lease renewal, completion idempotency, bounded structured results,
retry/failure behavior, tenant reads, column privileges, and worker-only grants.
Call-management coverage adds uploader/owner/admin authorization, normalized
display names, recoverable two-phase deletion, exact-object Storage deletion,
cascades, terminal-only manual retry, and deleting-call claim exclusion.
Call-history coverage adds literal bounded search, lifecycle filtering,
deterministic sorting, server-side pagination, response minimization, and tenant
isolation without exposing transcript, AI, or worker-private fields.

Run it after installing Docker and the Supabase CLI:

```bash
supabase start
supabase db reset
supabase test db
```

The test transaction rolls back its fixtures and does not leave test users or
workspace data behind.

pgTAP verifies that transcription and analysis worker claims use
`FOR UPDATE ... SKIP LOCKED` and exercises observable reclaim behavior, but it
does not simulate two truly concurrent database sessions. The production
functions therefore combine row locks, skip-locked selection, bounded batches,
fixed leases, and per-attempt claim tokens.
