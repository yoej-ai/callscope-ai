"""Trusted worker lifecycle for local speaker attribution jobs."""
from __future__ import annotations

import logging
import tempfile
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol
from urllib.parse import quote
from uuid import UUID

import httpx

from .core import MAX_FILE_BYTES, MIME_EXTENSIONS, Settings, verify_media_magic
from .diarization import (
    DiarizationError,
    LocalDiarizer,
    SpeakerRoleMapper,
    TranscriptSegment,
    TranscriptTurn,
    align_segments_to_speakers,
    apply_role_mapping,
    parse_transcript_segments,
)


LOG = logging.getLogger("callscope_worker.speaker_attribution")


class SpeakerWorkerError(Exception):
    """Safe machine-readable worker failure."""

    def __init__(self, code: str, *, retryable: bool) -> None:
        super().__init__(code)
        self.code = code
        self.retryable = retryable


@dataclass(frozen=True)
class SpeakerAttributionJob:
    call_id: str
    workspace_id: str
    storage_path: str
    content_type: str
    size_bytes: int
    segments: tuple[TranscriptSegment, ...]
    duration_ms: int
    claim_token: str
    attempt_count: int

    @property
    def suffix(self) -> str:
        return MIME_EXTENSIONS[self.content_type]

    @classmethod
    def from_row(cls, row: object) -> "SpeakerAttributionJob":
        if not isinstance(row, dict):
            raise SpeakerWorkerError("invalid_speaker_job", retryable=True)
        try:
            call_id = str(UUID(str(row["call_id"])))
            workspace_id = str(UUID(str(row["workspace_id"])))
            claim_token = str(UUID(str(row["claim_token"])))
            content_type = row["content_type"]
            storage_path = row["storage_path"]
            size_bytes = row["size_bytes"]
            attempt_count = row["attempt_count"]
            duration_seconds = row["duration_seconds"]
            if (
                row["storage_bucket"] != "call-audio"
                or not isinstance(content_type, str)
                or content_type not in MIME_EXTENSIONS
                or not isinstance(storage_path, str)
                or storage_path
                != f"{workspace_id}/{call_id}/source{MIME_EXTENSIONS[content_type]}"
                or type(size_bytes) is not int
                or not 1 <= size_bytes <= MAX_FILE_BYTES
                or type(attempt_count) is not int
                or not 1 <= attempt_count <= 3
                or type(duration_seconds) is not int
                or not 1 <= duration_seconds <= 3600
            ):
                raise ValueError("invalid claim metadata")
            duration_ms = duration_seconds * 1000
            segments = parse_transcript_segments(
                row["segments"], duration_ms=duration_ms
            )
        except (KeyError, TypeError, ValueError, AttributeError, DiarizationError) as exc:
            raise SpeakerWorkerError("invalid_speaker_job", retryable=True) from exc
        return cls(
            call_id,
            workspace_id,
            storage_path,
            content_type,
            size_bytes,
            segments,
            duration_ms,
            claim_token,
            attempt_count,
        )


class SpeakerGateway:
    """Private Storage download plus narrow worker-only speaker RPCs."""

    def __init__(self, settings: Settings, *, http: httpx.Client | None = None) -> None:
        self._owned_http = http is None
        headers = {
            "apikey": settings.supabase_key,
            "accept": "application/json",
            "content-type": "application/json",
            "accept-encoding": "identity",
        }
        if settings.use_bearer_auth:
            headers["authorization"] = "Bearer " + settings.supabase_key
        self.http = http or httpx.Client(
            base_url=settings.supabase_url.rstrip("/") + "/",
            headers=headers,
            timeout=httpx.Timeout(60.0, connect=15.0, read=60.0, write=30.0, pool=10.0),
            follow_redirects=False,
            trust_env=False,
        )

    def close(self) -> None:
        if self._owned_http:
            self.http.close()

    def _rpc(self, name: str, params: dict[str, object]) -> object:
        try:
            response = self.http.post(f"rest/v1/rpc/{name}", json=params)
            response.raise_for_status()
            return response.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise SpeakerWorkerError("speaker_rpc_unavailable", retryable=True) from exc

    def claim(self) -> list[SpeakerAttributionJob]:
        response = self._rpc("claim_speaker_attribution_jobs", {"p_limit": 1})
        if not isinstance(response, list) or len(response) > 1:
            raise SpeakerWorkerError("invalid_speaker_claim_response", retryable=True)
        return [SpeakerAttributionJob.from_row(row) for row in response]

    def renew(self, job: SpeakerAttributionJob) -> bool:
        return self._rpc(
            "renew_speaker_attribution_lease",
            {"p_call_id": job.call_id, "p_claim_token": job.claim_token},
        ) is True

    def download(self, job: SpeakerAttributionJob, target: Path) -> None:
        url = "storage/v1/object/authenticated/call-audio/" + quote(
            job.storage_path, safe="/"
        )
        total = 0
        try:
            with self.http.stream("GET", url) as response:
                if response.status_code in {400, 403, 404}:
                    raise SpeakerWorkerError("speaker_audio_unavailable", retryable=False)
                response.raise_for_status()
                with target.open("xb") as output:
                    for chunk in response.iter_bytes(chunk_size=1024 * 1024):
                        total += len(chunk)
                        if total > job.size_bytes or total > MAX_FILE_BYTES:
                            raise SpeakerWorkerError(
                                "speaker_audio_size_invalid", retryable=False
                            )
                        output.write(chunk)
        except SpeakerWorkerError:
            raise
        except (httpx.HTTPError, OSError) as exc:
            raise SpeakerWorkerError("speaker_audio_download_failed", retryable=True) from exc
        if total != job.size_bytes:
            raise SpeakerWorkerError("speaker_audio_size_invalid", retryable=False)

    def complete(
        self,
        job: SpeakerAttributionJob,
        turns: tuple[TranscriptTurn, ...],
    ) -> bool:
        response = self._rpc(
            "complete_speaker_attribution_job",
            {
                "p_call_id": job.call_id,
                "p_claim_token": job.claim_token,
                "p_turns": [turn.to_rpc_payload() for turn in turns],
            },
        )
        return isinstance(response, list) and any(
            isinstance(row, dict)
            and row.get("call_id") == job.call_id
            and row.get("status") == "completed"
            for row in response
        )

    def fail(self, job: SpeakerAttributionJob, error: SpeakerWorkerError) -> None:
        self._rpc(
            "fail_speaker_attribution_job",
            {
                "p_call_id": job.call_id,
                "p_claim_token": job.claim_token,
                "p_error_code": error.code,
                "p_retryable": error.retryable,
            },
        )


class SpeakerLeaseHeartbeat:
    def __init__(
        self,
        gateway: SpeakerGateway,
        job: SpeakerAttributionJob,
        *,
        interval_seconds: float = 60.0,
    ) -> None:
        if interval_seconds <= 0:
            raise ValueError("heartbeat interval must be positive")
        self.gateway = gateway
        self.job = job
        self.interval_seconds = interval_seconds
        self._stop = threading.Event()
        self.lost = False
        self._thread = threading.Thread(
            target=self._run,
            daemon=True,
            name="callscope-speaker-lease",
        )

    def _run(self) -> None:
        while not self._stop.wait(self.interval_seconds):
            try:
                if not self.gateway.renew(self.job):
                    self.lost = True
                    return
            except Exception:
                self.lost = True
                return

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join()


def _preflight(diarizer: LocalDiarizer) -> None:
    try:
        diarizer.preflight()
    except DiarizationError as exc:
        raise SpeakerWorkerError(exc.code, retryable=exc.retryable) from exc
    except Exception as exc:
        raise SpeakerWorkerError("diarization_preflight_error", retryable=True) from exc


def process_one_speaker_attribution(
    gateway: SpeakerGateway,
    diarizer: LocalDiarizer,
    role_mapper: SpeakerRoleMapper,
    *,
    heartbeat_interval_seconds: float = 60.0,
) -> bool:
    """Process at most one job after the local diarization preflight succeeds."""

    _preflight(diarizer)
    claimed = gateway.claim()
    if not claimed:
        return False
    job = claimed[0]
    heartbeat = SpeakerLeaseHeartbeat(
        gateway, job, interval_seconds=heartbeat_interval_seconds
    )
    heartbeat.start()
    try:
        with tempfile.TemporaryDirectory(prefix="callscope-speaker-") as temp:
            path = Path(temp) / ("source" + job.suffix)
            gateway.download(job, path)
            try:
                verify_media_magic(path, job.content_type)
            except Exception as exc:
                code = getattr(exc, "code", "speaker_media_invalid")
                retryable = bool(getattr(exc, "retryable", False))
                raise SpeakerWorkerError(code, retryable=retryable) from exc
            try:
                intervals = diarizer.diarize(path, duration_ms=job.duration_ms)
                turns = align_segments_to_speakers(job.segments, intervals)
            except DiarizationError as exc:
                raise SpeakerWorkerError(exc.code, retryable=exc.retryable) from exc
            turns = apply_role_mapping(turns, role_mapper)
            if heartbeat.lost:
                raise SpeakerWorkerError("speaker_lease_lost", retryable=True)
            if not gateway.complete(job, turns):
                raise SpeakerWorkerError("speaker_lease_lost", retryable=True)
            LOG.info("Speaker attribution completed for call %s", job.call_id)
    except SpeakerWorkerError as exc:
        LOG.warning(
            "Speaker attribution attempt ended: code=%s call=%s",
            exc.code,
            job.call_id,
        )
        if not heartbeat.lost:
            try:
                gateway.fail(job, exc)
            except SpeakerWorkerError:
                LOG.error("Could not record speaker attribution failure for %s", job.call_id)
    except Exception:
        LOG.error("Unexpected speaker attribution worker error for %s", job.call_id)
        if not heartbeat.lost:
            try:
                gateway.fail(
                    job,
                    SpeakerWorkerError("speaker_worker_error", retryable=True),
                )
            except SpeakerWorkerError:
                LOG.error("Could not record unexpected speaker failure for %s", job.call_id)
    finally:
        heartbeat.stop()
    return True
