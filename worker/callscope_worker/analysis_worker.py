"""Trusted CallScope AI analysis-worker lifecycle.

Responsibilities:
- Verify the local analysis engine before claiming database work.
- Claim completed transcripts through worker-only Supabase RPCs.
- Treat every transcript as untrusted input.
- Maintain the analysis lease while local inference is running.
- Pass only transcript text and optional language hint to the analyzer.
- Persist only validated AnalysisResult fields.
- Never log transcript text, model responses, reasoning, or secrets.
"""
from __future__ import annotations

import logging
import threading
from dataclasses import dataclass
from typing import Protocol
from uuid import UUID

import httpx

from .analysis import AnalysisResult
from .core import LANGUAGE_RE, Settings
from .ollama import OllamaError


LOG = logging.getLogger("callscope_worker.analysis")

MAX_TRANSCRIPT_CHARACTERS = 1_000_000


class AnalysisWorkerError(Exception):
    """Safe machine-readable analysis-worker failure."""

    def __init__(self, code: str, *, retryable: bool) -> None:
        super().__init__(code)
        self.code = code
        self.retryable = retryable


@dataclass(frozen=True)
class AnalysisJob:
    call_id: str
    workspace_id: str
    transcript_text: str
    language_code: str | None
    claim_token: str
    attempt_count: int

    @classmethod
    def from_row(cls, row: object) -> "AnalysisJob":
        if not isinstance(row, dict):
            raise AnalysisWorkerError(
                "invalid_analysis_job",
                retryable=True,
            )

        try:
            call_id = str(UUID(str(row["call_id"])))
            workspace_id = str(UUID(str(row["workspace_id"])))
            claim_token = str(UUID(str(row["claim_token"])))

            transcript_text = row["transcript_text"]
            language_code = row["language_code"]
            attempt_count = row["attempt_count"]

            if (
                not isinstance(transcript_text, str)
                or not transcript_text.strip()
                or len(transcript_text) > MAX_TRANSCRIPT_CHARACTERS
            ):
                raise ValueError("invalid transcript")

            if language_code is not None and (
                not isinstance(language_code, str)
                or len(language_code) > 24
                or not LANGUAGE_RE.fullmatch(language_code)
            ):
                raise ValueError("invalid language")

            if (
                type(attempt_count) is not int
                or not 1 <= attempt_count <= 3
            ):
                raise ValueError("invalid attempt")

        except (
            KeyError,
            TypeError,
            ValueError,
            AttributeError,
        ) as exc:
            raise AnalysisWorkerError(
                "invalid_analysis_job",
                retryable=True,
            ) from exc

        return cls(
            call_id=call_id,
            workspace_id=workspace_id,
            transcript_text=transcript_text,
            language_code=language_code,
            claim_token=claim_token,
            attempt_count=attempt_count,
        )


class Analyzer(Protocol):
    def preflight(self) -> None: ...

    def analyze(
        self,
        transcript: str,
        *,
        language: str | None,
    ) -> AnalysisResult: ...


class AnalysisGateway:
    """Least-privilege client for the Phase 4A analysis RPC boundary."""

    def __init__(
        self,
        settings: Settings,
        *,
        http: httpx.Client | None = None,
    ) -> None:
        self._owned_http = http is None

        headers = {
            "apikey": settings.supabase_key,
            "accept": "application/json",
            "content-type": "application/json",
            "accept-encoding": "identity",
        }

        if settings.use_bearer_auth:
            headers["authorization"] = (
                "Bearer " + settings.supabase_key
            )

        self.http = http or httpx.Client(
            base_url=settings.supabase_url.rstrip("/") + "/",
            headers=headers,
            timeout=httpx.Timeout(
                60.0,
                connect=15.0,
                read=60.0,
                write=30.0,
                pool=10.0,
            ),
            follow_redirects=False,
            trust_env=False,
        )

    def close(self) -> None:
        if self._owned_http:
            self.http.close()

    def _rpc(
        self,
        name: str,
        params: dict[str, object],
    ) -> object:
        try:
            response = self.http.post(
                f"rest/v1/rpc/{name}",
                json=params,
            )
            response.raise_for_status()
            return response.json()

        except (
            httpx.HTTPError,
            ValueError,
        ) as exc:
            raise AnalysisWorkerError(
                "analysis_rpc_unavailable",
                retryable=True,
            ) from exc

    def claim(self) -> list[AnalysisJob]:
        response = self._rpc(
            "claim_analysis_jobs",
            {
                "p_limit": 1,
            },
        )

        if (
            not isinstance(response, list)
            or len(response) > 1
        ):
            raise AnalysisWorkerError(
                "invalid_analysis_claim_response",
                retryable=True,
            )

        return [
            AnalysisJob.from_row(row)
            for row in response
        ]

    def renew(self, job: AnalysisJob) -> bool:
        response = self._rpc(
            "renew_analysis_lease",
            {
                "p_call_id": job.call_id,
                "p_claim_token": job.claim_token,
            },
        )

        return response is True

    def complete(
        self,
        job: AnalysisJob,
        result: AnalysisResult,
    ) -> bool:
        response = self._rpc(
            "complete_analysis_job",
            {
                "p_call_id": job.call_id,
                "p_claim_token": job.claim_token,
                "p_summary": result.summary,
                "p_sentiment": result.sentiment,
                "p_primary_intent": result.primary_intent,
                "p_objections": result.objections,
                "p_action_items": result.action_items,
                "p_topics": result.topics,
                "p_overall_score": result.overall_score,
            },
        )

        return (
            isinstance(response, list)
            and any(
                isinstance(row, dict)
                and row.get("call_id") == job.call_id
                and row.get("status") == "completed"
                for row in response
            )
        )

    def fail(
        self,
        job: AnalysisJob,
        error: AnalysisWorkerError,
    ) -> None:
        self._rpc(
            "fail_analysis_job",
            {
                "p_call_id": job.call_id,
                "p_claim_token": job.claim_token,
                "p_error_code": error.code,
                "p_retryable": error.retryable,
            },
        )


class AnalysisLeaseHeartbeat:
    """Renews the active claim without exposing job contents."""

    def __init__(
        self,
        gateway: AnalysisGateway,
        job: AnalysisJob,
        *,
        interval_seconds: float = 60.0,
    ) -> None:
        if interval_seconds <= 0:
            raise ValueError(
                "heartbeat interval must be positive"
            )

        self.gateway = gateway
        self.job = job
        self.interval_seconds = interval_seconds

        self._stop = threading.Event()

        self.lost = False

        self._thread = threading.Thread(
            target=self._run,
            daemon=True,
            name="callscope-analysis-lease",
        )

    def _run(self) -> None:
        while not self._stop.wait(
            self.interval_seconds
        ):
            try:
                if not self.gateway.renew(self.job):
                    self.lost = True
                    return

            except Exception:
                # Never log RPC bodies or private claim metadata here.
                self.lost = True
                return

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

        self._thread.join(
            timeout=5,
        )


def _run_preflight(analyzer: Analyzer) -> None:
    """Verify inference availability before any database job is claimed."""

    try:
        analyzer.preflight()

    except OllamaError as exc:
        raise AnalysisWorkerError(
            exc.code,
            retryable=exc.retryable,
        ) from exc

    except Exception as exc:
        # Do not include the original exception message. A third-party
        # implementation could expose local paths, payloads, or configuration.
        raise AnalysisWorkerError(
            "analysis_preflight_error",
            retryable=True,
        ) from exc


def process_one_analysis(
    gateway: AnalysisGateway,
    analyzer: Analyzer,
    *,
    heartbeat_interval_seconds: float = 60.0,
) -> bool:
    """Process at most one analysis claim.

    Returns False only when the queue is empty.

    Before any database claim is attempted, the analyzer must successfully
    complete its local preflight check. This prevents infrastructure failures
    such as a stopped Ollama process or missing model from consuming a database
    analysis attempt.

    Completion is attempted only when:
    - analyzer preflight succeeded before the claim,
    - model inference succeeded,
    - the model result passed local strict validation,
    - and the worker still owns the active lease.
    """

    _run_preflight(analyzer)

    claimed = gateway.claim()

    if not claimed:
        return False

    job = claimed[0]

    heartbeat = AnalysisLeaseHeartbeat(
        gateway,
        job,
        interval_seconds=heartbeat_interval_seconds,
    )

    heartbeat.start()

    try:
        try:
            analysis = analyzer.analyze(
                job.transcript_text,
                language=job.language_code,
            )

        except OllamaError as exc:
            raise AnalysisWorkerError(
                exc.code,
                retryable=exc.retryable,
            ) from exc

        if heartbeat.lost:
            raise AnalysisWorkerError(
                "analysis_lease_lost",
                retryable=True,
            )

        if not gateway.complete(
            job,
            analysis,
        ):
            raise AnalysisWorkerError(
                "analysis_lease_lost",
                retryable=True,
            )

        LOG.info(
            "Analysis completed for call %s",
            job.call_id,
        )

    except AnalysisWorkerError as exc:
        LOG.warning(
            "Analysis attempt ended: code=%s call=%s",
            exc.code,
            job.call_id,
        )

        if not heartbeat.lost:
            try:
                gateway.fail(
                    job,
                    exc,
                )

            except AnalysisWorkerError:
                LOG.error(
                    "Could not record analysis failure for call %s",
                    job.call_id,
                )

    except Exception:
        # Never include exception details: a downstream exception could
        # accidentally contain transcript or model data.
        LOG.error(
            "Unexpected analysis worker error for call %s",
            job.call_id,
        )

        if not heartbeat.lost:
            try:
                gateway.fail(
                    job,
                    AnalysisWorkerError(
                        "analysis_worker_error",
                        retryable=True,
                    ),
                )

            except AnalysisWorkerError:
                LOG.error(
                    "Could not record unexpected analysis failure for call %s",
                    job.call_id,
                )

    finally:
        heartbeat.stop()

    return True