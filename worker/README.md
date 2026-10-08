# CallScope AI — Phase 3B isolated transcription worker

This optional trusted local worker is NOT a frontend feature or public FastAPI
endpoint. It claims uploaded calls using Phase 3A's PostgreSQL RPCs, reads
audio from the private Supabase Storage bucket, transcribes on CPU with the
free Faster-Whisper engine, and saves output through the worker-only RPC.

## Prerequisites

- Python 3.12 or newer; FFmpeg/ffprobe installed and on PATH
- Supabase database with the Phase 3A SQL migration applied
- CPU and disk space for the free Whisper model
- Worker-only `SUPABASE_SECRET_KEY` in the private worker environment, or a
  legacy `SUPABASE_SERVICE_ROLE_KEY` JWT for backward compatibility
- Appropriate recording consent and privacy/retention/deletion controls

## Setup (from worker/)

1. Create virtual environment: python -m venv .venv
2. Activate .venv, then install: python -m pip install -e ".[speech,dev]"
3. Install FFmpeg (including ffprobe) via the OS package manager.
4. Supply private process environment variables `SUPABASE_URL`, the preferred
   `SUPABASE_SECRET_KEY`, and optionally `WHISPER_MODEL=tiny`. The tracked
   `.env.example` contains dummy values only; the worker does not automatically
   load a `.env` file. `SUPABASE_SERVICE_ROLE_KEY` remains supported only for a
   legacy service-role JWT. Do not configure both key variables with different
   values.
5. Run one job: callscope-transcribe
6. Run a continuous process on a trusted machine:
   callscope-transcribe --loop --poll-seconds 30

The speech extra intentionally constrains PyAV to `>=11,<19`: the current
Faster-Whisper integration uses an `av.open` API that is incompatible with
PyAV 19. This is a compatibility constraint, not a security downgrade; do not
remove it until upstream compatibility has been verified.

The free model may download at initial startup; private recordings are not
sent to any transcription API or hosted LLM. A local worker processes only
while its computer is running. Do not put any secret-role credentials in web/,
api/, GitHub Actions secrets for builds, logs, or NEXT_PUBLIC_* variables.

Modern `sb_secret_...` credentials are sent only in Supabase's `apikey` header;
they are not JWTs and must never be sent as `Authorization: Bearer` values.
Legacy service-role JWTs retain the compatible `apikey` plus Bearer headers.
Both credential types belong only in this trusted server-side worker runtime.

## Existing safeguards

- Claims one job at a time through the service-role-only database RPCs.
- Exact workspace/call object path, MIME and maximum 25 MiB size validation.
- Downloads through the private authenticated Storage route with no redirects
  to third-party hosts; bounds every download by the expected database size.
- Temporary audio stored in a private temporary directory and deleted after
  processing. Magic-signature checks and ffprobe reject corrupt, unexpected,
  non-audio, and longer-than-60-minute recordings.
- Lease renewed every 60 seconds, completion requires current claim token.
- SQL limits processing attempts to three and retry delay to five minutes.
- Logs only status and safe machine-readable error codes, not transcripts,
  private audio, sensitive authorization headers, URLs, or HTTP response bodies.
- Unit tests run offline in GitHub CI without downloading model weights.

## Hosted validation status

The Phase 3A transcription migration is deployed to hosted Supabase, with hosted
migration history aligned through
`20261009000000_transcription_foundation.sql`. The worker has been verified in
two hosted end-to-end scenarios through the real private ingestion path:

- A synthetic silent WAV was claimed and downloaded securely, processed by
  Faster-Whisper, rejected as `invalid_transcript`, and transitioned safely to
  `failed`. Retry and state-machine behavior remained intact.
- A real spoken MP3 uploaded through the dashboard was automatically queued,
  claimed, downloaded from private Storage, and transcribed locally. Completion
  succeeded on the first attempt, transcript text and duration were stored, and
  the tenant-protected Call Detail page displayed the transcript.

These checks prove the hosted failure and success paths without making the worker
an always-on production service. No private identifiers, recording content, or
credentials are recorded here.

## Before production

Never expose a modern Supabase secret or legacy service-role JWT to the browser.
For any new environment, confirm the exact target project, backup, and migration
history before applying migrations separately under explicit approval.

This is not a hardened media-decoding sandbox. For untrusted uploads, run the
worker in a restricted container or OS sandbox with no unnecessary network
egress, finite CPU/memory/disk quotas, up-to-date FFmpeg packages, and secure
secrets management. Add monitoring, model caching, true concurrency tests,
live end-to-end checks, and transcript retention/deletion procedures before
processing customer recordings in production. No production worker deployment
or always-on free hosting is part of this implementation. The local/manual worker
processes jobs only while its machine is running. The default Whisper `tiny`
model may misrecognize proper names or language labels; that is a model-quality
limitation rather than a pipeline failure.
