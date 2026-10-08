# Database security tests

The numbered pgTAP suites cover the foundation RLS model, private audio ingestion,
stale upload reconciliation, transcription, and the AI-analysis state foundation.
The worker-boundary suites exercise auto-queue and backfill behavior, claims,
wall-clock lease renewal, completion idempotency, bounded structured results,
retry/failure behavior, tenant reads, column privileges, and worker-only grants.

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
