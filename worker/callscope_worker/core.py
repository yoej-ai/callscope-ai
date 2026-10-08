"""Least-privilege worker RPC client and guarded job lifecycle.

All service_role operations happen only in this isolated worker process.
No raw media, transcripts, access tokens, or response bodies are logged.
"""
from __future__ import annotations

import json
import logging
import os
import re
import tempfile
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol
from urllib.parse import quote, urlsplit
from uuid import UUID

import httpx

LOG = logging.getLogger("callscope_worker")
MAX_FILE_BYTES = 25 * 1024 * 1024
MIME_EXTENSIONS = {
    "audio/mpeg": ".mp3",
    "audio/mp4": ".mp4",
    "audio/x-m4a": ".m4a",
    "audio/wav": ".wav",
    "audio/webm": ".webm",
    "audio/ogg": ".ogg",
}
LANGUAGE_RE = re.compile(r"^[a-z]{2,3}(?:-[a-z0-9]{2,8}){0,2}$")


class WorkerError(Exception):
    """Safe, machine-readable failure code; never contains transcript or secrets."""

    def __init__(self, code: str, *, retryable: bool) -> None:
        super().__init__(code)
        self.code = code
        self.retryable = retryable


@dataclass(frozen=True)
class Settings:
    supabase_url: str
    service_role_key: str
    model: str

    @classmethod
    def from_env(cls) -> "Settings":
        value = os.getenv("SUPABASE_URL", "").rstrip("/")
        key = os.getenv("SUPABASE_SERVICE_ROLE_KEY", "")
        model = os.getenv("WHISPER_MODEL", "tiny")
        url = urlsplit(value)
        local_host = url.hostname in {"localhost", "127.0.0.1"}
        if (
            not value
            or not url.hostname
            or (url.scheme != "https" and not (url.scheme == "http" and local_host))
            or url.username is not None
            or url.password is not None
            or url.path not in {"", "/"}
            or url.query
            or url.fragment
        ):
            raise ValueError("SUPABASE_URL must be an HTTPS origin or local Supabase HTTP origin")
        if not key or key == "replace-with-local-service-role-key":
            raise ValueError("A worker-only SUPABASE_SERVICE_ROLE_KEY is required")
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]{0,99}", model):
            raise ValueError("WHISPER_MODEL must be a simple model identifier")
        return cls(value, key, model)


@dataclass(frozen=True)
class Job:
    call_id: str
    workspace_id: str
    storage_path: str
    content_type: str
    size_bytes: int
    claim_token: str
    attempt_count: int

    @property
    def suffix(self) -> str:
        return MIME_EXTENSIONS[self.content_type]

    @classmethod
    def from_row(cls, row: object) -> "Job":
        if not isinstance(row, dict):
            raise WorkerError("invalid_job", retryable=True)
        try:
            call_id = str(UUID(str(row["call_id"])))
            workspace_id = str(UUID(str(row["workspace_id"])))
            token = str(UUID(str(row["claim_token"])))
            mime = row["content_type"]
            path = row["storage_path"]
            size = row["size_bytes"]
            attempts = row["attempt_count"]
            if (
                row["storage_bucket"] != "call-audio"
                or not isinstance(mime, str)
                or mime not in MIME_EXTENSIONS
                or not isinstance(path, str)
                or path != f"{workspace_id}/{call_id}/source{MIME_EXTENSIONS[mime]}"
                or type(size) is not int
                or not 1 <= size <= MAX_FILE_BYTES
                or type(attempts) is not int
                or not 1 <= attempts <= 3
            ):
                raise ValueError("invalid claim metadata")
        except (KeyError, TypeError, ValueError, AttributeError) as exc:
            raise WorkerError("invalid_job", retryable=True) from exc
        return cls(call_id, workspace_id, path, mime, size, token, attempts)


@dataclass(frozen=True)
class Transcript:
    text: str
    language: str | None
    segments: list[dict[str, object]]
    duration_seconds: int | None

    def validate(self) -> None:
        if not self.text.strip() or len(self.text) > 1_000_000:
            raise WorkerError("invalid_transcript", retryable=False)
        if self.language is not None and (
            len(self.language) > 24 or not LANGUAGE_RE.fullmatch(self.language)
        ):
            raise WorkerError("invalid_language", retryable=False)
        if not isinstance(self.segments, list) or len(json.dumps(self.segments).encode()) > 4_000_000:
            raise WorkerError("invalid_segments", retryable=False)
        if self.duration_seconds is not None and (
            type(self.duration_seconds) is not int
            or not 0 <= self.duration_seconds <= 604800
        ):
            raise WorkerError("invalid_duration", retryable=False)


class Transcriber(Protocol):
    def transcribe(self, path: Path) -> Transcript: ...


def verify_media_magic(path: Path, mime: str) -> None:
    """Cheap rejection of mismatched files; ffprobe must validate actual audio."""
    with path.open("rb") as audio:
        head = audio.read(16)
    signatures = {
        "audio/mpeg": head.startswith(b"ID3") or (
            len(head) >= 2 and head[0] == 0xFF and head[1] & 0xE0 == 0xE0
        ),
        "audio/mp4": len(head) >= 12 and head[4:8] == b"ftyp",
        "audio/x-m4a": len(head) >= 12 and head[4:8] == b"ftyp",
        "audio/wav": head[:4] == b"RIFF" and head[8:12] == b"WAVE",
        "audio/webm": head[:4] == b"\x1a\x45\xdf\xa3",
        "audio/ogg": head[:4] == b"OggS",
    }
    if not signatures.get(mime, False):
        raise WorkerError("media_signature_invalid", retryable=False)


class Gateway:
    """Supabase Storage and PostgREST access; never serializes secrets in logs."""

    def __init__(self, settings: Settings, http: httpx.Client | None = None) -> None:
        self._owned = http is None
        self.http = http or httpx.Client(
            base_url=settings.supabase_url + "/",
            headers={
                "apikey": settings.service_role_key,
                "authorization": "Bearer " + settings.service_role_key,
                "accept-encoding": "identity",
            },
            timeout=httpx.Timeout(60, connect=15),
            follow_redirects=False,
            trust_env=False,
        )

    def close(self) -> None:
        if self._owned:
            self.http.close()

    def _rpc(self, name: str, params: dict[str, object]) -> object:
        try:
            response = self.http.post(f"rest/v1/rpc/{name}", json=params)
            response.raise_for_status()
            return response.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise WorkerError("rpc_unavailable", retryable=True) from exc

    def claim(self) -> list[Job]:
        response = self._rpc("claim_transcription_jobs", {"p_limit": 1})
        if not isinstance(response, list) or len(response) > 1:
            raise WorkerError("invalid_claim_response", retryable=True)
        return [Job.from_row(row) for row in response]

    def renew(self, job: Job) -> bool:
        return self._rpc("renew_transcription_lease", {
            "p_call_id": job.call_id, "p_claim_token": job.claim_token
        }) is True

    def download(self, job: Job, target: Path) -> None:
        url = "storage/v1/object/authenticated/call-audio/" + quote(
            job.storage_path, safe="/"
        )
        total = 0
        try:
            with self.http.stream("GET", url) as response:
                if response.status_code in {400, 403, 404}:
                    raise WorkerError("audio_unavailable", retryable=False)
                response.raise_for_status()
                with target.open("xb") as output:
                    for chunk in response.iter_bytes(chunk_size=1024 * 1024):
                        total += len(chunk)
                        if total > job.size_bytes or total > MAX_FILE_BYTES:
                            raise WorkerError("audio_size_invalid", retryable=False)
                        output.write(chunk)
        except WorkerError:
            raise
        except (httpx.HTTPError, OSError) as exc:
            raise WorkerError("audio_download_failed", retryable=True) from exc
        if total != job.size_bytes:
            raise WorkerError("audio_size_invalid", retryable=False)

    def complete(self, job: Job, transcript: Transcript) -> bool:
        result = self._rpc("complete_transcription_job", {
            "p_call_id": job.call_id,
            "p_claim_token": job.claim_token,
            "p_transcript_text": transcript.text,
            "p_language_code": transcript.language,
            "p_segments": transcript.segments,
            "p_duration_seconds": transcript.duration_seconds,
        })
        return isinstance(result, list) and any(
            isinstance(row, dict)
            and row.get("call_id") == job.call_id
            and row.get("status") == "completed"
            for row in result
        )

    def fail(self, job: Job, error: WorkerError) -> None:
        self._rpc("fail_transcription_job", {
            "p_call_id": job.call_id,
            "p_claim_token": job.claim_token,
            "p_error_code": error.code,
            "p_retryable": error.retryable,
        })


class LeaseHeartbeat:
    def __init__(self, gateway: Gateway, job: Job, interval_seconds: float = 60) -> None:
        self.gateway, self.job = gateway, job
        self.interval_seconds = interval_seconds
        self._stop = threading.Event()
        self.lost = False
        self._thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        while not self._stop.wait(self.interval_seconds):
            try:
                if not self.gateway.renew(self.job):
                    self.lost = True
                    return
            except Exception:
                # Do not log HTTP responses: they could contain private metadata.
                self.lost = True
                return

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=5)


def process_one(gateway: Gateway, transcriber: Transcriber) -> bool:
    """Process up to one claim; False means the queue was empty.

    A failed/expired lease never gets a completion request.
    """
    claimed = gateway.claim()
    if not claimed:
        return False
    job = claimed[0]
    keeper = LeaseHeartbeat(gateway, job)
    keeper.start()
    try:
        with tempfile.TemporaryDirectory(prefix="callscope-audio-") as temp:
            path = Path(temp) / ("source" + job.suffix)
            gateway.download(job, path)
            verify_media_magic(path, job.content_type)
            transcript = transcriber.transcribe(path)
            transcript.validate()
            if keeper.lost:
                raise WorkerError("lease_lost", retryable=True)
            if not gateway.complete(job, transcript):
                raise WorkerError("lease_lost", retryable=True)
            LOG.info("Transcription completed for call %s", job.call_id)
    except WorkerError as exc:
        LOG.warning("Transcription attempt ended: code=%s call=%s", exc.code, job.call_id)
        if not keeper.lost:
            try:
                gateway.fail(job, exc)
            except WorkerError:
                LOG.error("Could not record transcription failure for call %s", job.call_id)
    except Exception:
        LOG.error("Unexpected worker error for call %s", job.call_id)
        if not keeper.lost:
            try:
                gateway.fail(job, WorkerError("worker_error", retryable=True))
            except WorkerError:
                LOG.error("Could not record unexpected failure for call %s", job.call_id)
    finally:
        keeper.stop()
    return True
