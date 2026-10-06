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
- Server-side dashboard authorization plus session refresh in `proxy.ts`
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
`/sign-in`, `/auth/callback`, and the protected `/dashboard`.

Frontend environment variables:

| Variable | Purpose |
| --- | --- |
| `NEXT_PUBLIC_SUPABASE_URL` | Public Supabase project URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Public Supabase anon/publishable key |

Only the public Supabase URL and anon key belong in browser configuration.
Never place a service-role key in `web/` or any `NEXT_PUBLIC_*` variable.

## Authentication architecture

`@supabase/ssr` provides separate browser and server clients. `proxy.ts` refreshes
cookie-backed sessions and redirects obvious unauthenticated dashboard requests.
The dashboard independently calls `auth.getUser()` on the server before rendering,
so the proxy is not treated as the authorization boundary. The database remains
protected by RLS even if an application-layer check is missed.

For hosted email confirmation, add the deployed callback URL to **Authentication
→ URL Configuration → Redirect URLs** in Supabase:

```text
https://your-domain.example/auth/callback
```

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

RLS rules enforce the following model:

- users can read and update only their own profile name
- workspace members can read their workspace and membership roster
- owners and admins can rename a workspace; only owners can delete it
- owners may assign `admin` or `member`; admins may assign only `member`
- members cannot add users, change roles, or remove users
- owners cannot demote themselves through the browser policy
- workspace members can read calls, analyses, and usage for their tenant
- browser roles have no mutation grants for calls, analyses, or usage events yet
- anonymous users have no application-table privileges

Membership checks run through narrowly scoped `SECURITY DEFINER` functions in the
non-exposed `private` schema. They use an empty `search_path`, fully qualified
objects, revoked default execution, and no client-supplied user ID. This avoids
recursive `workspace_members` policies without broadening table access.

## Supabase setup and migrations

1. Install Docker and the Supabase CLI.
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

- copy the project URL and anon/publishable key into `web/.env.local`
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
no production secrets.

## Current limitations

- workspace creation is available at the database RPC layer but has no UI yet
- membership invitations and ownership transfer are intentionally not implemented
- call, analysis, and usage mutation is reserved for future trusted workflows
- there is no audio storage, upload, transcription, LLM, vector, billing, or CRM code
- API authentication and deployment configuration belong to a later phase

## Recommended next phase

Build the workspace onboarding flow: call `create_workspace`, add a workspace
selector, and establish a trusted API authentication boundary. Only after tenant
selection and authorization tests are proven should the project add Supabase
Storage policies and an audio-upload state machine.
