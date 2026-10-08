# Database security tests

The numbered pgTAP suites cover the foundation RLS model, private audio ingestion,
stale upload reconciliation, and the transcription state machine and worker
boundary. Transcription tests exercise claim, renewal, completion idempotency,
retry/failure behavior, tenant reads, column privileges, and worker-only grants.

Run it after installing Docker and the Supabase CLI:

```bash
supabase start
supabase db reset
supabase test db
```

The test transaction rolls back its fixtures and does not leave test users or
workspace data behind.

pgTAP verifies that worker claims use `FOR UPDATE ... SKIP LOCKED` and exercises
the observable reclaim behavior, but it does not simulate two truly concurrent
database sessions. The production function therefore combines row locks,
skip-locked selection, bounded batches, fixed leases, and per-attempt claim tokens.
