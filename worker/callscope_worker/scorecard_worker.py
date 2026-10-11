"""Trusted worker lifecycle for pinned custom AI scorecards."""
from __future__ import annotations

import logging
import threading
from dataclasses import dataclass
from typing import Protocol, Sequence
from uuid import UUID

import httpx

from .core import LANGUAGE_RE, Settings
from .ollama import OllamaError
from .scorecard import (
    ScorecardCriterion,
    ScorecardModelResult,
    ScorecardValidationError,
    parse_scorecard_criteria,
)


LOG = logging.getLogger("callscope_worker.scorecard")
MAX_TRANSCRIPT_CHARACTERS = 1_000_000


class ScorecardWorkerError(Exception):
    """Safe machine-readable scorecard worker failure."""

    def __init__(self, code: str, *, retryable: bool) -> None:
        super().__init__(code)
        self.code = code
        self.retryable = retryable


@dataclass(frozen=True)
class ScorecardJob:
    scorecard_id: str
    call_id: str
    workspace_id: str
    playbook_version_id: str
    transcript_text: str
    language_code: str | None
    criteria: tuple[ScorecardCriterion, ...]
    claim_token: str
    attempt_count: int

    @classmethod
    def from_row(cls, row: object) -> "ScorecardJob":
        if not isinstance(row, dict):
            raise ScorecardWorkerError("invalid_scorecard_job", retryable=True)
        try:
            scorecard_id = str(UUID(str(row["scorecard_id"])))
            call_id = str(UUID(str(row["call_id"])))
            workspace_id = str(UUID(str(row["workspace_id"])))
            playbook_version_id = str(UUID(str(row["playbook_version_id"])))
            claim_token = str(UUID(str(row["claim_token"])))
            transcript_text = row["transcript_text"]
            language_code = row["language_code"]
            attempt_count = row["attempt_count"]
            criteria = parse_scorecard_criteria(row["criteria"])
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
            if type(attempt_count) is not int or not 1 <= attempt_count <= 3:
                raise ValueError("invalid attempt")
        except (
            KeyError,
            TypeError,
            ValueError,
            AttributeError,
            ScorecardValidationError,
        ) as exc:
            raise ScorecardWorkerError("invalid_scorecard_job", retryable=True) from exc
        return cls(
            scorecard_id,
            call_id,
            workspace_id,
            playbook_version_id,
            transcript_text,
            language_code,
            criteria,
            claim_token,
            attempt_count,
        )


class ScorecardAnalyzer(Protocol):
    def preflight(self) -> None: ...

    def analyze(
        self,
        transcript: str,
        *,
        language: str | None,
        criteria: Sequence[ScorecardCriterion],
    ) -> ScorecardModelResult: ...


class ScorecardGateway:
    """Least-privilege client for worker-only scorecard RPCs."""

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
            raise ScorecardWorkerError("scorecard_rpc_unavailable", retryable=True) from exc

    def claim(self) -> list[ScorecardJob]:
        response = self._rpc("claim_scorecard_jobs", {"p_limit": 1})
        if not isinstance(response, list) or len(response) > 1:
            raise ScorecardWorkerError(
                "invalid_scorecard_claim_response", retryable=True
            )
        return [ScorecardJob.from_row(row) for row in response]

    def renew(self, job: ScorecardJob) -> bool:
        return self._rpc(
            "renew_scorecard_lease",
            {
                "p_scorecard_id": job.scorecard_id,
                "p_claim_token": job.claim_token,
            },
        ) is True

    def complete(self, job: ScorecardJob, result: ScorecardModelResult) -> bool:
        response = self._rpc(
            "complete_scorecard_job",
            {
                "p_scorecard_id": job.scorecard_id,
                "p_claim_token": job.claim_token,
                "p_criteria": result.to_rpc_payload(),
            },
        )
        return isinstance(response, list) and any(
            isinstance(row, dict)
            and row.get("scorecard_id") == job.scorecard_id
            and row.get("status") == "completed"
            for row in response
        )

    def fail(self, job: ScorecardJob, error: ScorecardWorkerError) -> None:
        self._rpc(
            "fail_scorecard_job",
            {
                "p_scorecard_id": job.scorecard_id,
                "p_claim_token": job.claim_token,
                "p_error_code": error.code,
                "p_retryable": error.retryable,
            },
        )


class ScorecardLeaseHeartbeat:
    def __init__(
        self,
        gateway: ScorecardGateway,
        job: ScorecardJob,
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
            name="callscope-scorecard-lease",
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


def _run_preflight(analyzer: ScorecardAnalyzer) -> None:
    try:
        analyzer.preflight()
    except OllamaError as exc:
        raise ScorecardWorkerError(exc.code, retryable=exc.retryable) from exc
    except Exception as exc:
        raise ScorecardWorkerError(
            "scorecard_preflight_error", retryable=True
        ) from exc


def process_one_scorecard(
    gateway: ScorecardGateway,
    analyzer: ScorecardAnalyzer,
    *,
    heartbeat_interval_seconds: float = 60.0,
) -> bool:
    """Process at most one scorecard after local Ollama preflight succeeds."""

    _run_preflight(analyzer)
    claimed = gateway.claim()
    if not claimed:
        return False
    job = claimed[0]
    heartbeat = ScorecardLeaseHeartbeat(
        gateway,
        job,
        interval_seconds=heartbeat_interval_seconds,
    )
    heartbeat.start()
    try:
        try:
            result = analyzer.analyze(
                job.transcript_text,
                language=job.language_code,
                criteria=job.criteria,
            )
        except OllamaError as exc:
            raise ScorecardWorkerError(exc.code, retryable=exc.retryable) from exc
        if heartbeat.lost:
            raise ScorecardWorkerError("scorecard_lease_lost", retryable=True)
        if not gateway.complete(job, result):
            raise ScorecardWorkerError("scorecard_lease_lost", retryable=True)
        LOG.info("Scorecard completed for scorecard %s", job.scorecard_id)
    except ScorecardWorkerError as exc:
        LOG.warning(
            "Scorecard attempt ended: code=%s scorecard=%s",
            exc.code,
            job.scorecard_id,
        )
        if not heartbeat.lost:
            try:
                gateway.fail(job, exc)
            except ScorecardWorkerError:
                LOG.error("Could not record scorecard failure for %s", job.scorecard_id)
    except Exception:
        LOG.error("Unexpected scorecard worker error for %s", job.scorecard_id)
        if not heartbeat.lost:
            try:
                gateway.fail(
                    job,
                    ScorecardWorkerError("scorecard_worker_error", retryable=True),
                )
            except ScorecardWorkerError:
                LOG.error(
                    "Could not record unexpected scorecard failure for %s",
                    job.scorecard_id,
                )
    finally:
        heartbeat.stop()
    return True
