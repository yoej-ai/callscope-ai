# CallScope AI — local worker orchestration

This trusted local worker is not a frontend feature or public FastAPI endpoint.
The `callscope-worker` supervisor runs the transcription, generic AI-analysis,
and custom scorecard pipelines together while keeping their resources and
failure handling isolated.
It reuses the existing one-job processing functions and service-role-only RPCs;
it does not bypass claim tokens, leases, heartbeats, retry state, or RLS.

## Prerequisites

- Python 3.12 or newer; FFmpeg/ffprobe installed and on PATH
- Supabase database with the transcription, analysis, Playbook, and scorecard
  migrations applied
- CPU and disk space for the free Whisper model
- Local Ollama listening only on loopback, with `qwen3:4b-instruct` available
- Worker-only `SUPABASE_SECRET_KEY` in the private worker environment, or a
  legacy `SUPABASE_SERVICE_ROLE_KEY` JWT for backward compatibility
- Appropriate recording consent and privacy/retention/deletion controls

## Setup (from worker/)

1. Create virtual environment: python -m venv .venv
2. Activate .venv, then install: python -m pip install -e ".[speech,dev]"
3. Install FFmpeg (including ffprobe) via the OS package manager.
4. Install Ollama locally and run `ollama pull qwen3:4b-instruct`.
5. Supply private process environment variables `SUPABASE_URL`, the preferred
   `SUPABASE_SECRET_KEY`, and optionally `WHISPER_MODEL=tiny`. The tracked
   `.env.example` contains dummy values only; the worker does not automatically
   load a `.env` file. `SUPABASE_SERVICE_ROLE_KEY` remains supported only for a
   legacy service-role JWT. Do not configure both key variables with different
   values. `OLLAMA_BASE_URL` defaults to the loopback-only
   `http://127.0.0.1:11434`, and `OLLAMA_MODEL` defaults to
   `qwen3:4b-instruct`.
6. Start all three continuous pipelines on the trusted local machine:

   ```text
   callscope-worker
   ```

7. Press Ctrl+C to stop all three pipelines cleanly.

The supervisor polls empty queues every 30 seconds by default. Infrastructure
failures retry independently with exponential backoff from 5 seconds up to a
60-second cap. These values can be changed with `--poll-seconds`,
`--initial-backoff-seconds`, and `--max-backoff-seconds`; use
`callscope-worker --help` for the bounded option ranges.

Ollama or model preflight failure occurs before an analysis or scorecard claim,
so it does not consume an attempt. The affected pipeline backs off while the
other pipelines continue. Supabase or transcription-side infrastructure failure
is likewise contained to the transcription loop while healthy model pipelines
continue. Failures are logged using only the pipeline name, bounded error code,
and retry delay.

## Phase 9A custom scorecards

An owner or admin selects one stable workspace Playbook identity for future AI
scorecards. When an eligible completed transcript is queued, the database
resolves the newest published version at that moment and permanently pins its
exact `playbook_version_id`. Changing the selection or publishing a later
version never rewrites an existing scorecard. Historical eligible calls can be
queued explicitly through the same bounded, idempotent database path.

The dedicated local scorecard analyzer sends only the transcript, language hint,
and ordered published criteria to loopback Ollama. Both transcript and Playbook
text are untrusted data. The model has no tools, secrets, database, files, or
external actions and may return only one validated outcome per criterion:
`pass`, `fail`, `not_applicable`, or `insufficient_evidence`. Raw model output,
reasoning, transcript copies, evidence snippets, and timestamps are not stored.
Explainable evidence is intentionally deferred to a later phase.

The model never supplies the numeric score. Database completion validates the
exact criterion set, then calculates `passed eligible weight / total eligible
weight * 100`, rounded half-up to two decimals. `not_applicable` is excluded
from the denominator. `insufficient_evidence` is also excluded and sets
`review_required`; zero eligible weight produces a null score and requires
review. The shared Python helper cross-tests these same Phase 8B semantics, but
the database remains authoritative for production persistence.

This feature makes no model-accuracy claim. The repository evaluation dataset
is synthetic and is not a human-reviewed production benchmark.
The Phase 9A migration and scorecard feature are repository/local-only at this
review point; they have not been deployed to hosted Supabase.

Common startup and preflight codes are deliberately safe and actionable:

| Pipeline/code | Operator action |
| --- | --- |
| `worker_configuration_invalid` | Check that the private worker environment has a valid Supabase origin and exactly one supported privileged worker key. Do not print the values. |
| `ffprobe_unavailable` | Install FFmpeg/ffprobe and ensure it is on `PATH`. |
| `speech_dependencies_unavailable` | Install the worker's `speech` extra in the active environment. |
| `transcription_model_unavailable` | Check local model availability, disk space, and network access needed for the initial public model download. |
| `analysis_configuration_invalid` | Restore the loopback-only Ollama URL and a valid local model identifier. |
| `ollama_unavailable` | Start local Ollama; transcription continues independently. |
| `ollama_model_unavailable` | Run `ollama pull qwen3:4b-instruct`, or pull the safely configured local model. |

The supervisor never appends exception messages or configuration values to
these logs. Repeated failures retain the capped backoff and do not become a
tight loop. An analysis preflight failure still occurs before a claim and does
not consume a database attempt.

Ctrl+C and supported termination signals set a shared stop event. Idle and
backoff waits wake immediately, no loop starts another job after observing
shutdown, in-flight work is allowed to finish safely, and all pipelines close
their owned HTTP clients before the process exits. This behavior uses standard
Python threads and signals and is supported for local Windows development.

The existing one-shot and single-pipeline commands remain available:

```text
callscope-transcribe
callscope-analyze
callscope-transcribe --loop --poll-seconds 30
callscope-analyze --loop --poll-seconds 30
```

The speech extra intentionally constrains PyAV to `>=11,<19`: the current
Faster-Whisper integration uses an `av.open` API that is incompatible with
PyAV 19. This is a compatibility constraint, not a security downgrade; do not
remove it until upstream compatibility has been verified.

Faster-Whisper remains responsible for multilingual transcription and language
detection. The worker stores a normalized language code only when the model's
reported detection probability is at least 0.80 and the metadata is valid. It
stores no language code when confidence is weaker or metadata is unreliable;
it never substitutes English merely because detection was uncertain.

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
- Analysis checks local Ollama and the configured model before claiming work.
- The supervisor isolates all three loops and caps infrastructure retry backoff.
- Logs only status and safe machine-readable error codes, not transcripts,
  prompts, raw model responses, private audio, sensitive authorization headers,
  URLs, or HTTP response bodies. No hidden reasoning is persisted.
- Normal `httpx` and `httpcore` request logging is suppressed.
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
processing customer recordings in production. The supervisor is the current
local MVP operating strategy only. It is not an always-on production or cloud
deployment and provides no autoscaling, production monitoring, HA, or process
manager. It processes jobs only while its machine is running. The default
Whisper `tiny` model may misrecognize proper names or language labels; that is a
model-quality limitation rather than a pipeline failure.
