# CallScope AI

CallScope AI is a multi-user call-intelligence SaaS foundation for sales and
support teams. It is designed to turn customer conversations into secure,
searchable summaries, intent, sentiment, objections, scores, and action items.

This repository currently contains the production-oriented V1 foundation. It
does **not** yet upload audio, transcribe calls, invoke LLMs, or integrate with
billing and CRM systems.

## Foundation scope

- Next.js 16 App Router frontend with responsive public and authenticated UI
- Supabase email/password authentication using cookie-backed SSR sessions
- Server-side dashboard/onboarding authorization plus session refresh in `proxy.ts`
- Authenticated workspace onboarding and RLS-backed workspace selection
- PostgreSQL tenant model, constraints, indexes, triggers, and Row Level Security
- Atomic workspace creation RPC that assigns the authenticated creator as owner
- FastAPI service with typed configuration, logging, CORS, errors, and `/health`
- Frontend, backend, and database-security CI jobs

## Architecture

```text
Browser
  │
  ├── Next.js web/ ── cookie-backed Supabase Auth
  │       │
  │       └── Supabase PostgreSQL ── RLS is the tenant boundary
  │
  └── FastAPI api/ ── future server-side application operations
```

The frontend handles presentation and authentication. FastAPI is an independent
service boundary for future trusted workflows. PostgreSQL constraints and RLS
provide durable data integrity and tenant isolation; neither route protection
nor application validation replaces those database controls.

## Repository structure

```text
.
├── web/                    Next.js application
├── api/                    FastAPI application and pytest suite
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
`/sign-in`, `/auth/callback`, and the protected `/onboarding` and `/dashboard`
routes.

Frontend environment variables:

| Variable | Purpose |
| --- | --- |
| `APP_URL` | Trusted server-only application origin used for auth callbacks |
| `NEXT_PUBLIC_SUPABASE_URL` | Public Supabase project URL |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | Browser-safe Supabase publishable key |

For local development, set `APP_URL=http://localhost:3000`. If it is omitted while
Next.js is running in development mode, that localhost origin is the only fallback.
In production and other non-development environments, `APP_URL` is required and
must be an absolute `http://` or `https://` origin without credentials, a path,
query parameters, or a fragment. Invalid configured values always fail clearly.

`APP_URL` is server-only and must never be prefixed with `NEXT_PUBLIC_`. Only the
public Supabase URL and publishable key belong in browser configuration. Put real
local values in ignored `web/.env.local`; never commit them. Never place a Supabase
secret or legacy service-role key in `web/` or any `NEXT_PUBLIC_*` variable.

## Authentication architecture

`@supabase/ssr` provides separate browser and server clients. `proxy.ts` refreshes
cookie-backed sessions and redirects obvious unauthenticated dashboard and
onboarding requests. Both protected pages independently call `auth.getUser()` on
the server before rendering, so the proxy is not treated as the authorization
boundary. The database remains protected by RLS even if an application-layer
check is missed.

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
| `SUPABASE_URL` | Supabase project URL for future server integrations |

`CORS_ORIGINS` must not contain `*` because credentialed requests are enabled.
The current health endpoint does not require Supabase credentials.

## Database overview

The migration creates:

- `profiles`: one user-owned profile linked to `auth.users`
- `workspaces`: tenant records with the original creator recorded
- `workspace_members`: unique user membership with `owner`, `admin`, or `member`
- `calls`: workspace-scoped call metadata and processing state
- `call_analyses`: one structured analysis record per call
- `usage_events`: append-only usage/telemetry records for later metering

Foreign keys define deliberate delete behavior. Checks reject blank names and
paths, invalid roles or statuses, negative duration, out-of-range lead scores,
non-positive usage quantities, and malformed JSON container types. Mutable tables
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

Manual hosted-project steps:

- copy the project URL and publishable key into ignored `web/.env.local`
- configure the local and deployed authentication callback URLs
- review email-provider and confirmation settings
- apply the migration and run the security tests
- set production frontend and API origins

## Testing and validation

Frontend:

```bash
cd web
npm ci
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

GitHub Actions runs all three validation groups on pushes and pull requests. CI
uses harmless public placeholders for build-time Supabase variables and contains
no production secrets. Database CI uses the official `supabase/setup-cli` action
at release `v3.0.1` and pins Supabase CLI `2.119.0` rather than floating on latest.

## Current limitations

- onboarding creates the first workspace; invitations, ownership transfer, and
  workspace deletion UI are intentionally not implemented
- workspace selection uses a validated URL query parameter and is not persisted
  in local storage, cookies, or global client state
- call and analysis mutation is reserved for future trusted workflows
- raw usage events have no browser access; no aggregate usage API exists yet
- there is no audio storage, upload, transcription, LLM, vector, billing, or CRM code
- API authentication and deployment configuration belong to a later phase

## Recommended next phase

Reconcile hosted migration history separately, then establish a trusted API
authentication boundary. Only after that boundary and tenant authorization tests
are proven should the project add Supabase Storage policies and an audio-upload
state machine.

