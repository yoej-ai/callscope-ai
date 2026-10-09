# CallScope AI

CallScope AI is a multi-user call-intelligence SaaS foundation for sales and
support teams. It is designed to turn customer conversations into secure,
searchable summaries, intent, sentiment, objections, scores, and action items.

This repository contains the production-oriented V1 foundation, private
tenant-authorized audio ingestion, transcription and AI-analysis state machines,
isolated transcription and analysis workers, and a tenant-safe Call Detail
experience. The source implements the complete upload, transcription, analysis,
and structured-insights flow. Repository history records hosted end-to-end
validation of both the secure transcription and AI-analysis paths; that evidence
does not mean the local workers are always running or that an external hosted
project's migration state remains continuously current. The workers are operated
locally and manually. Local AI analysis uses Ollama with Qwen3 4B Instruct and
requires no paid model API for development and testing. Speaker diarization,
billing, vector search, CRM integrations, and always-on production worker
deployment remain future work.

## Foundation scope

- Next.js 16 App Router frontend with responsive public and authenticated UI
- Supabase email/password authentication using cookie-backed SSR sessions
- Server-side dashboard/onboarding authorization plus session refresh in `proxy.ts`
- Authenticated workspace onboarding and RLS-backed workspace selection
- Server-side Next.js integration with the authenticated FastAPI boundary
- PostgreSQL tenant model, constraints, indexes, triggers, and Row Level Security
- Atomic workspace creation RPC that assigns the authenticated creator as owner
- FastAPI service with typed configuration, logging, CORS, errors, and `/health`
- JWKS-verified Supabase user authentication for protected API routes
- RLS-scoped workspace lookup through the user-authenticated Supabase Data API
- Private Supabase Storage uploads initiated and finalized through FastAPI
- User-triggered recovery for interrupted and stale pending uploads
- RLS-protected transcript state and worker-only claim/lease/retry RPCs
- Isolated local CPU worker using free Faster-Whisper transcription
- Isolated local Ollama analysis worker using Qwen3 4B Instruct
- Strict schema-constrained AI results with prompt-injection hardening
- Tenant-safe server-rendered call detail, transcript, and AI-insights views
- Bounded AI-analysis state, worker RPC boundary, and live queued/processing refresh
- Frontend, backend, worker, and database-security CI jobs

## Architecture

```text
Browser
  │
  └── Next.js web/ ── cookie-backed Supabase Auth
          │
          ├── Supabase PostgreSQL ── RLS-visible workspace switcher
          │
          └── FastAPI api/ ── independently verified user JWT
                  │
                  ├── Supabase Data API ── user Bearer token ── PostgreSQL RLS
                  └── private Supabase Storage ── signed upload target

Trusted local worker/
  ├── service-role-only claim/lease/result RPCs
  ├── private Storage download and media validation
  └── local Faster-Whisper CPU transcription
```

The frontend handles presentation and the browser session. Protected dashboard
requests first establish trusted identity with Supabase `auth.getUser()` on the
Next.js server. Only afterward does server code use `auth.getSession()` to obtain
the access token for forwarding; session data and `session.user` are not treated
as the authorization authority. The token is never passed to a Client Component
or rendered into the page.

Next.js forwards the user access token to FastAPI using the server-only `API_URL`.
FastAPI independently verifies the token before protected API work. For tenant
reads it forwards that same user token to the Supabase Data API, so PostgreSQL
RLS—not a client-supplied user ID or privileged API key—remains the durable
authorization boundary. Neither route protection nor application validation
replaces those database controls, and no service-role key is involved.

## Repository structure

```text
.
├── web/                    Next.js application
├── api/                    FastAPI application and pytest suite
├── worker/                 Isolated local transcription worker and tests
├── supabase/
│   ├── migrations/         Versioned database schema and policies
│   └── tests/              pgTAP RLS/security tests
├── .github/workflows/      Continuous integration
├── .gitignore
└── README.md
```

## Frontend setup

Requirements: Node.js 20.9 or newer and npm.

```bash
cd web
cp .env.example .env.local
npm install
npm run dev
```

Open `http://localhost:3000`. Available routes include `/`, `/sign-up`,
`/sign-in`, `/auth/callback`, the protected `/onboarding` and `/dashboard`
routes, and tenant-protected call details at `/dashboard/calls/{call_id}`.

Frontend environment variables:

| Variable | Purpose |
| --- | --- |
| `APP_URL` | Trusted server-only application origin used for auth callbacks |
| `API_URL` | Server-only FastAPI origin used by protected dashboard requests |
| `NEXT_PUBLIC_SUPABASE_URL` | Public Supabase project URL |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | Browser-safe Supabase publishable key |

For local development, set `APP_URL=http://localhost:3000` and
`API_URL=http://127.0.0.1:8000`. `API_URL` is loaded lazily only when protected
FastAPI-backed functionality runs. It accepts HTTPS origins and permits HTTP only
for `localhost` or `127.0.0.1`; credentials, paths, queries, fragments, and
malformed URLs are rejected.

If `APP_URL` is omitted while Next.js is running in development mode, its
localhost origin is the only fallback. In production and other non-development
environments, `APP_URL` is required and must be an absolute `http://` or `https://`
origin without credentials, a path, query parameters, or a fragment. Invalid
configured values always fail clearly.

`APP_URL` and `API_URL` are server-only and must never be prefixed with
`NEXT_PUBLIC_`. Only the public Supabase URL and publishable key belong in browser
configuration. Put real local values in ignored `web/.env.local`; never commit
them. Never place a Supabase secret or legacy service-role key in `web/` or any
`NEXT_PUBLIC_*` variable.

## Authentication architecture

`@supabase/ssr` provides separate browser and server clients. `proxy.ts` refreshes
cookie-backed sessions and redirects obvious unauthenticated dashboard and
onboarding requests. Both protected pages independently call `auth.getUser()` on
the server before rendering, so the proxy is not treated as the authorization
boundary. The database remains protected by RLS even if an application-layer
check is missed.

On the dashboard, the RLS-visible workspace list still comes from the signed-in
Supabase SSR client and determines the only acceptable active workspace IDs. Once
`auth.getUser()` has established the user, server code retrieves the session only
to obtain its access token. It then calls FastAPI `/v1/me`, compares the verified
API `user_id` to the trusted Supabase user ID, and calls
`/v1/workspaces/{workspace_id}`. The returned workspace ID must match the requested
RLS-visible ID before its name is displayed. Authentication, identity, workspace,
network, and response-shape failures stop the flow with a safe error; the frontend
does not silently bypass FastAPI.

Sign-up confirmation always uses `${APP_URL}/auth/callback`; request `Origin` and
`Host` headers are not trusted. Configure Supabase **Authentication → URL
Configuration** consistently:

- Local Site URL: `http://localhost:3000`
- Local allowed redirect URL: `http://localhost:3000/auth/callback`
- Production Site URL: the exact production `APP_URL`
- Production allowed redirect URL: the production `APP_URL` plus `/auth/callback`

For example, `APP_URL=https://app.example.com` requires the allowed redirect URL
`https://app.example.com/auth/callback`.

## Backend setup

Requirements: Python 3.12 or newer.

```bash
cd api
python -m venv .venv
# Windows: .venv\Scripts\activate
# macOS/Linux: source .venv/bin/activate
python -m pip install -e ".[dev]"
uvicorn app.main:app --reload
```

Backend environment variables:

| Variable | Purpose |
| --- | --- |
| `APP_ENV` | Runtime environment, such as `development` or `production` |
| `CORS_ORIGINS` | Comma-separated explicit frontend origins |
| `SUPABASE_URL` | Supabase project origin used to derive Auth JWKS, issuer, and Data API URLs |
| `SUPABASE_PUBLISHABLE_KEY` | Browser-safe project key sent only as the Data API `apikey` header |

`CORS_ORIGINS` must not contain `*` because credentialed requests are enabled.
`GET /health` remains public and does not contact Supabase. Protected routes fail
safely when their Supabase configuration is absent. Put real deployment values in
the runtime environment or an ignored `api/.env`; the tracked example contains
placeholders only.

The API does not require a Supabase secret key, legacy `service_role` key, legacy
JWT secret, or database password for this boundary.

### API authentication and authorization

Protected endpoints require `Authorization: Bearer <Supabase user access token>`.
The API obtains asymmetric signing keys from
`<SUPABASE_URL>/auth/v1/.well-known/jwks.json`, caches them, and refreshes the JWKS
once when an unfamiliar key ID indicates signing-key rotation. PyJWT and
`cryptography` verify the signature. Validation requires:

- an allowed asymmetric signing algorithm (`ES256` or `RS256`)
- the exact issuer `<SUPABASE_URL>/auth/v1`
- the `authenticated` audience and role
- a non-expired token
- a UUID `sub`, which becomes the authorization identity

Unsigned, malformed, expired, incorrectly signed, wrong-project, non-user, and
publishable-key bearer credentials are rejected. Raw access tokens and complete
claim sets are never returned by the API.

Available endpoints:

- `GET /health` — public liveness response
- `GET /v1/me` — returns only the verified user UUID and safe role
- `GET /v1/workspaces/{workspace_id}` — returns the requested workspace only when
  it is visible through the verified user's existing RLS policies
- `POST /v1/workspaces/{workspace_id}/calls/uploads` — creates a pending call and
  returns a short-lived signed upload target for its database-generated path
- `POST /v1/workspaces/{workspace_id}/calls/{call_id}/complete` — verifies the
  exact stored object's metadata and moves the call to `uploaded`
- `POST /v1/workspaces/{workspace_id}/calls/uploads/reconcile` — reconciles a
  bounded batch of the authenticated user's stale pending uploads

Workspace lookup sends the configured publishable key in `apikey` and the
verified user access token in `Authorization`. It queries only the requested UUID
and selects only `id`, `name`, and `created_at`. A missing workspace and a
workspace hidden by another tenant's RLS policy both return the same generic 404;
the API performs no privileged existence check.

### Private audio ingestion

Audio is stored in the private `call-audio` bucket. The database, not a browser,
creates every object path as
`{workspace_id}/{call_id}/source.{validated_extension}`. Upload authorization is
tied to the authenticated user, workspace membership, the pending call row, and
that exact path. FastAPI uses the user's bearer token plus the publishable key to
create the pending row and request a signed upload token; it does not use a
secret or service-role credential.

The dashboard provides a single-recording upload form and RLS-scoped call history.
The browser asks same-origin Next.js Route Handlers to initiate and complete an
upload. Those handlers re-establish the user with `auth.getUser()`, verify that the
workspace is in the user's RLS-visible set, and only then obtain the session token
for server-to-server FastAPI calls. The raw bearer token never enters Client
Component props or browser application state. The browser uploads the file itself
only to the short-lived, signed private Storage target returned by the initiate
handler; the signed token is neither persisted nor placed in a URL by application
code.

Accepted files are MP3, MP4 audio, M4A, WAV, WebM audio, and Ogg audio, with a
maximum declared size of 25 MiB. Filename extension, MIME type, and size must all
pass both API and database validation. Completion is a separate, idempotent step
that checks the exact Storage object and its recorded size and MIME type before
marking the call `uploaded`. Browser clients receive no general object update,
delete, or listing capability.

If signed-token creation fails before the browser can begin uploading, FastAPI
uses the existing authenticated abort helper to remove the unused pending row.
Once a browser Storage request has started, an error can be ambiguous, so the row
remains pending instead of being deleted. The dashboard refreshes call history and
allows the user to retry the existing exact finalization check.

Users can also trigger a bounded reconciliation of up to 20 of their own pending
uploads that are at least four hours old. The fixed four-hour threshold is longer
than the two-hour signed-upload lifetime and cannot be supplied by the browser.
Reconciliation uses row locks, removes a stale row only when its exact object is
absent, marks it uploaded only when exact size and MIME metadata match, and marks
metadata mismatches failed. It does not delete Storage objects or add Storage
read, update, or delete policies.

The pgTAP suite verifies the locking clauses and their observable state changes,
but does not simulate two truly concurrent database sessions. Production
reconciliation therefore keeps the conservative age threshold and skip-locked
row processing as defense in depth.

The ingestion boundary does not inspect file bytes. Before transcription, the
trusted worker validates the downloaded media signature and metadata, probes it
with FFmpeg, and enforces size and duration bounds. Local validation uses the
free local Supabase stack and does not require paid services.

### Secure transcription foundation

Every call that reaches `uploaded` with its exact trusted `call-audio` path,
content type, size, and completion timestamp receives one queued
`call_transcriptions` row. A trigger handles new finalizations with
`ON CONFLICT DO NOTHING`; the forward migration applies the same strict predicate
when backfilling existing uploaded calls. Pending, failed, and incomplete legacy
rows are not queued.

The transcription lifecycle is separate from `calls.status`: `queued`,
`processing`, `completed`, and `failed` live only on `call_transcriptions`.
Authenticated workspace members can select safe transcript fields through RLS,
while claim tokens, leases, retry timing, attempt counts, and internal error codes
have no browser-readable grants. The call-detail page queries only safe columns
and displays a generic failed state rather than worker diagnostics.

Four `SECURITY DEFINER` RPCs form the trusted-worker boundary. Only the
Supabase `service_role` database role can execute them; anonymous and
authenticated roles cannot, and the browser never receives service-role
credentials. The existing FastAPI user service has no service-role configuration.
Claims are oldest-first, limited to five, protected by `FOR UPDATE SKIP LOCKED`,
and use fixed fifteen-minute leases with fresh claim tokens. A matching active
token can renew, complete, or report failure. Completion retains the hidden token
so a same-token retry after response loss is idempotent. Retryable failures wait
five minutes and stop after three claims; only bounded machine-readable error
codes are stored.

The recorded hosted Phase 3A validation confirmed that RLS was enabled on
`call_transcriptions`, authenticated users could read only safe tenant transcript
columns, `claim_token` remained browser-hidden, and mutation RPCs remained
service-role-only. Later recorded hosted AI-analysis validation exercised the
analysis foundation that follows this migration. Treat these as validation
records rather than a continuously current statement about external deployment
state.

### Trusted transcription worker

Phase 3B adds an isolated worker in `worker/`. It securely claims queued jobs,
downloads the exact recording from private Storage, validates and probes the
media, transcribes locally on CPU with free Faster-Whisper, and reports the result
through the token-protected completion RPC. Modern Supabase `sb_secret_`
credentials use `apikey` authentication only; legacy service-role JWTs remain
supported for backward compatibility. Privileged credentials stay entirely in
the worker environment.

The speech dependency intentionally constrains PyAV to `av>=11,<19` for current
Faster-Whisper compatibility. Dedicated worker CI installs the speech
dependencies, checks that ceiling, and runs the offline worker suite without
instantiating a Whisper model or downloading model weights.

### Phase 3B hosted end-to-end validation

Both major paths have been verified through the real hosted pipeline:

- A synthetic silent WAV was securely claimed and downloaded, then rejected as
  `invalid_transcript` after Faster-Whisper produced no usable text. The job
  transitioned safely to `failed`, confirming failure and retry behavior.
- A real spoken MP3 uploaded through the dashboard was queued automatically,
  claimed and downloaded privately, transcribed locally, and completed on the
  first attempt. The transcript and duration were stored and the tenant-protected
  Call Detail page displayed the completed transcript.

The proven flow is:

```text
Browser upload → authenticated FastAPI ingestion → private Supabase Storage
→ uploaded call → automatic transcription queue → trusted worker claim
→ private audio download → local Faster-Whisper transcription → completion RPC
→ Supabase transcript record → authenticated Call Detail UI transcript display
```

This validation proves the functional and security path; it is not a claim of an
always-on or production-scale transcription deployment.

### Secure AI analysis

Phase 4A established the analysis state machine and automatically queues one
analysis job only after a valid transcription is completed. The database enforces
a bounded result contract for summary, sentiment, primary intent, objections,
action items, topics, and an optional 0–100 engagement/opportunity score. Tenant
members can select only safe result and status columns through RLS; claim tokens,
leases, attempts, retry timing, and internal error codes remain hidden.

Phase 4B adds the isolated trusted analysis worker. It uses local Ollama with
Qwen3 4B Instruct, claims work only through the existing service-role-only
`SECURITY DEFINER` RPC boundary, renews active leases while inference runs, and
persists only locally validated structured fields. The model receives no
Supabase credential, files, database access, browser session, external tools, or
network-capable tool interface.

Transcript text is always treated as untrusted data rather than instructions.
The system prompt explicitly excludes analyzer-directed commands and
prompt-injection content from business analysis. Thinking is disabled, tool use
is absent, the response is constrained by a closed JSON schema, and the worker
never stores raw model responses or hidden reasoning.

Phase 4C strengthens reliability before database claims. The worker performs a
local Ollama/model preflight before claiming a job so a stopped Ollama process or
missing configured model does not consume an analysis attempt. Normal INFO logs
from `httpx` and `httpcore` are suppressed to avoid unnecessary request metadata.

The `overall_score` is defined as an engagement/opportunity score rather than a
sentiment score. Genuine business conversations retain bounded 0–100 scores,
while transcripts with no genuine business intent, such as workflow tests or
noise, return no score. A deterministic post-validation safeguard converts
model-generated numeric scores to `null` only when the validated result itself
contains no business intent, objections, action items, or topics.

The Call Detail page renders queued, processing, failed, and completed states
using only tenant-safe columns. While transcription or analysis is queued or
processing, the page refreshes periodically when visible so completed results can
appear without a manual reload. Worker credentials never enter the browser.

## Database overview

The migration creates:

- `profiles`: one user-owned profile linked to `auth.users`
- `workspaces`: tenant records with the original creator recorded
- `workspace_members`: unique user membership with `owner`, `admin`, or `member`
- `calls`: workspace-scoped call metadata and processing state
- `call_transcriptions`: one RLS-protected transcript state/result per eligible call
- `call_analyses`: one RLS-protected structured analysis state/result per completed transcript
- `usage_events`: append-only usage/telemetry records for later metering

Foreign keys define deliberate delete behavior. Checks reject blank names and
paths, invalid roles or statuses, negative duration, out-of-range analysis scores,
non-positive usage quantities, and malformed or oversized structured results. Mutable tables
share a single `updated_at` trigger. Authorization/query paths have dedicated indexes.

## Workspace and authorization model

Tenant access begins with `workspace_members`. The public
`create_workspace(p_name)` RPC validates `auth.uid()` and atomically inserts both
the workspace and its owner membership. It never accepts an owner user ID.

An authenticated user without an accessible workspace is redirected from the
dashboard to `/onboarding`. The onboarding form calls only `create_workspace`;
application code does not insert directly into tenant or membership tables. After
creation, the returned workspace ID is selected through
`/dashboard?workspace=<uuid>`.

The dashboard queries `workspaces` through the signed-in SSR client and lets RLS
determine the visible set. A requested workspace query parameter becomes active
only when it matches that server-loaded set. Missing, malformed, stale, or
unauthorized values fall back to the first accessible workspace ordered by
`created_at` and then `id`, without revealing whether another tenant exists.

RLS rules enforce the following model:

- users can read and update only their own profile name
- workspace members can read their workspace and membership roster
- owners and admins can rename a workspace; only owners can delete it
- owners may assign `admin` or `member`; admins may assign only `member`
- members cannot add users, change roles, or remove users
- owners cannot demote themselves through the browser policy
- workspace members can read calls and analyses for their tenant
- workspace members can read only safe transcript columns for their tenant
- browser roles cannot mutate transcription jobs or read worker claim/lease fields
- worker job RPC execution is reserved exclusively for `service_role`
- raw `usage_events` rows have no anonymous or authenticated browser privileges
- future usage reporting must use a narrowly scoped aggregate RPC or trusted API
- anonymous users have no application-table privileges

Membership checks run through narrowly scoped `SECURITY DEFINER` functions in the
non-exposed `private` schema. They use an empty `search_path`, fully qualified
objects, revoked default execution, and no client-supplied user ID. This avoids
recursive `workspace_members` policies without broadening table access.

## Supabase setup and migrations

1. Install Docker and Supabase CLI `2.119.0` to match CI.
2. Start the local stack and apply migrations:

   ```bash
   supabase start
   supabase db reset
   ```

3. Run the database security suite:

   ```bash
   supabase test db
   ```

For a hosted project, link the CLI to the intended project and review the target
before running `supabase db push`. The migration changes authentication triggers,
grants, and RLS policies, so apply it first in a non-production environment.

The repository contains versioned migrations through
`20261010000000_ai_analysis_foundation.sql`. Repository history records hosted
end-to-end validation of both transcription and AI analysis, but hosted project
state is external to this source tree and may change. Verify the live migration
history and target independently before applying changes; do not infer current
deployment state from this README alone.

Manual hosted-project steps:

- copy the project URL and publishable key into ignored `web/.env.local`
- configure the local and deployed authentication callback URLs
- review email-provider and confirmation settings
- verify the intended migration history and run the security tests locally
- set production frontend and API origins

## Testing and validation

Frontend:

```bash
cd web
npm ci
npm test
npm run lint
npm run typecheck
npm run build
```

Backend:

```bash
cd api
python -m pip install -e ".[dev]"
pytest
```

Database:

```bash
supabase start
supabase db reset
supabase test db
```

GitHub Actions runs frontend, backend, worker, and database validation on pushes
and pull requests. Worker CI installs the speech dependencies but does not
instantiate Faster-Whisper or download model weights. CI
uses harmless public placeholders for build-time Supabase variables and contains
no production secrets. Database CI uses the official `supabase/setup-cli` action
at release `v3.0.1` and pins Supabase CLI `2.119.0` rather than floating on latest.

## Current limitations

- onboarding creates the first workspace; invitations, ownership transfer, and
  workspace deletion UI are intentionally not implemented
- workspace selection uses a validated URL query parameter and is not persisted
  in local storage, cookies, or global client state
- FastAPI integration is server-side; browsers do not manually receive its bearer
  token through rendered props or client state
- JWKS and workspace reads require the configured Supabase service to be reachable
- analysis mutation remains restricted to service-role-only worker RPCs;
  the local Ollama worker has no direct table mutation grant
- raw usage events have no browser access; no aggregate usage API exists yet
- byte-level media validation occurs in the trusted worker, not at browser upload
- stale reconciliation is user-triggered and bounded; automatic scheduling and
  trusted deletion of invalid or orphaned Storage objects remain deferred
- the transcription worker is local/manual and processes jobs only while its
  machine is running; no always-on cloud or production-scale worker exists
- AI Call Analysis & Insights runs through the local Ollama worker; speaker
  diarization, vector search, billing, CRM integrations, and always-on cloud
  inference are not implemented
- the default Whisper `tiny` model can misrecognize proper names or language
  labels; this is a model-quality limitation rather than a pipeline failure

## Recommended next phase

After Phase 4C reliability hardening, the next product phase should focus on
running the completed transcription and analysis pipeline as a more usable SaaS
workflow without weakening the existing tenant, RLS, private Storage, and
claim-token boundaries. Candidate work includes an explicit worker-operation
strategy, broader end-to-end product validation, improved transcription language
quality, and product-level insights workflows.

Speaker diarization, vector search, billing, CRM integrations, and always-on
production worker deployment remain separate future phases. Paid model services
are not required for the current local development and validation path.

