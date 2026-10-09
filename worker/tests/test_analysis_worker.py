from __future__ import annotations

import json

import httpx
import pytest

from callscope_worker.analysis import AnalysisResult
from callscope_worker.analysis_worker import (
    AnalysisGateway,
    AnalysisJob,
    AnalysisWorkerError,
    process_one_analysis,
)
from callscope_worker.core import Settings
from callscope_worker.ollama import OllamaError


CALL = "20000000-0000-0000-0000-000000000041"
WORKSPACE = "10000000-0000-0000-0000-000000000041"
TOKEN = "30000000-0000-0000-0000-000000000041"

MODERN_SECRET = "sb_secret_unit_test_not_real"


def settings() -> Settings:
    return Settings(
        "https://unit-test.supabase.co",
        MODERN_SECRET,
        False,
        "tiny",
    )


def claim_payload(**overrides: object) -> dict[str, object]:
    value: dict[str, object] = {
        "call_id": CALL,
        "workspace_id": WORKSPACE,
        "transcript_text": "Customer asked about pricing.",
        "language_code": "en",
        "claim_token": TOKEN,
        "attempt_count": 1,
    }
    value.update(overrides)
    return value


def job() -> AnalysisJob:
    return AnalysisJob.from_row(claim_payload())


def result() -> AnalysisResult:
    return AnalysisResult.from_mapping(
        {
            "summary": "Customer asked about pricing.",
            "sentiment": "neutral",
            "primary_intent": "pricing inquiry",
            "objections": [],
            "action_items": ["Send pricing information"],
            "topics": ["pricing"],
            "overall_score": 70,
        }
    )


def test_analysis_job_validates_claim_contract() -> None:
    item = job()

    assert item.call_id == CALL
    assert item.workspace_id == WORKSPACE
    assert item.transcript_text == "Customer asked about pricing."
    assert item.language_code == "en"
    assert item.claim_token == TOKEN
    assert item.attempt_count == 1


@pytest.mark.parametrize(
    "override",
    [
        {"call_id": "bad"},
        {"workspace_id": "bad"},
        {"claim_token": "bad"},
        {"transcript_text": ""},
        {"transcript_text": " "},
        {"transcript_text": "x" * 1_000_001},
        {"language_code": "not a language"},
        {"attempt_count": 0},
        {"attempt_count": 4},
        {"attempt_count": True},
    ],
)
def test_analysis_job_rejects_invalid_claim_data(
    override: dict[str, object],
) -> None:
    with pytest.raises(AnalysisWorkerError):
        AnalysisJob.from_row(claim_payload(**override))


def test_analysis_job_accepts_null_language() -> None:
    item = AnalysisJob.from_row(
        claim_payload(language_code=None)
    )

    assert item.language_code is None


def test_analysis_gateway_uses_exact_phase4a_rpc_contract() -> None:
    seen: list[tuple[str, dict[str, object]]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        payload = json.loads(request.content)
        seen.append((request.url.path, payload))

        if request.url.path.endswith("/rpc/claim_analysis_jobs"):
            return httpx.Response(
                200,
                json=[claim_payload()],
            )

        if request.url.path.endswith("/rpc/renew_analysis_lease"):
            return httpx.Response(
                200,
                json=True,
            )

        if request.url.path.endswith("/rpc/complete_analysis_job"):
            return httpx.Response(
                200,
                json=[
                    {
                        "call_id": CALL,
                        "status": "completed",
                    }
                ],
            )

        if request.url.path.endswith("/rpc/fail_analysis_job"):
            return httpx.Response(
                200,
                json=[
                    {
                        "call_id": CALL,
                        "status": "queued",
                    }
                ],
            )

        return httpx.Response(404)

    with httpx.Client(
        base_url="https://unit-test.supabase.co/",
        headers={"apikey": MODERN_SECRET},
        transport=httpx.MockTransport(handler),
    ) as http:
        gateway = AnalysisGateway(
            settings(),
            http=http,
        )

        claimed = gateway.claim()

        assert len(claimed) == 1

        item = claimed[0]

        assert gateway.renew(item) is True
        assert gateway.complete(item, result()) is True

        gateway.fail(
            item,
            AnalysisWorkerError(
                "ollama_unavailable",
                retryable=True,
            ),
        )

    assert seen[0] == (
        "/rest/v1/rpc/claim_analysis_jobs",
        {"p_limit": 1},
    )

    assert seen[1] == (
        "/rest/v1/rpc/renew_analysis_lease",
        {
            "p_call_id": CALL,
            "p_claim_token": TOKEN,
        },
    )

    assert seen[2] == (
        "/rest/v1/rpc/complete_analysis_job",
        {
            "p_call_id": CALL,
            "p_claim_token": TOKEN,
            "p_summary": "Customer asked about pricing.",
            "p_sentiment": "neutral",
            "p_primary_intent": "pricing inquiry",
            "p_objections": [],
            "p_action_items": ["Send pricing information"],
            "p_topics": ["pricing"],
            "p_overall_score": 70,
        },
    )

    assert seen[3] == (
        "/rest/v1/rpc/fail_analysis_job",
        {
            "p_call_id": CALL,
            "p_claim_token": TOKEN,
            "p_error_code": "ollama_unavailable",
            "p_retryable": True,
        },
    )


class FakeAnalysisGateway:
    def __init__(self) -> None:
        self.completed: list[AnalysisResult] = []
        self.failed: list[AnalysisWorkerError] = []
        self.renew_result = True
        self.claim_calls = 0

    def claim(self) -> list[AnalysisJob]:
        self.claim_calls += 1
        return [job()]

    def renew(self, item: AnalysisJob) -> bool:
        return self.renew_result

    def complete(
        self,
        item: AnalysisJob,
        analysis: AnalysisResult,
    ) -> bool:
        self.completed.append(analysis)
        return True

    def fail(
        self,
        item: AnalysisJob,
        error: AnalysisWorkerError,
    ) -> None:
        self.failed.append(error)


class FakeAnalyzer:
    def __init__(
        self,
        *,
        preflight_error: Exception | None = None,
        analysis_error: Exception | None = None,
    ) -> None:
        self.preflight_error = preflight_error
        self.analysis_error = analysis_error
        self.preflight_calls = 0
        self.calls = 0

    def preflight(self) -> None:
        self.preflight_calls += 1

        if self.preflight_error is not None:
            raise self.preflight_error

    def analyze(
        self,
        transcript: str,
        *,
        language: str | None,
    ) -> AnalysisResult:
        self.calls += 1

        assert transcript == "Customer asked about pricing."
        assert language == "en"

        if self.analysis_error is not None:
            raise self.analysis_error

        return result()


def test_analysis_worker_preflights_before_claiming_job() -> None:
    gateway = FakeAnalysisGateway()
    analyzer = FakeAnalyzer()

    assert process_one_analysis(
        gateway,
        analyzer,
        heartbeat_interval_seconds=3600,
    ) is True

    assert analyzer.preflight_calls == 1
    assert gateway.claim_calls == 1
    assert analyzer.calls == 1


def test_analysis_worker_preflight_failure_does_not_claim_job() -> None:
    gateway = FakeAnalysisGateway()
    analyzer = FakeAnalyzer(
        preflight_error=OllamaError(
            "ollama_unavailable",
            retryable=True,
        )
    )

    with pytest.raises(AnalysisWorkerError) as error:
        process_one_analysis(
            gateway,
            analyzer,
            heartbeat_interval_seconds=3600,
        )

    assert error.value.code == "ollama_unavailable"
    assert error.value.retryable is True

    assert analyzer.preflight_calls == 1
    assert gateway.claim_calls == 0
    assert analyzer.calls == 0
    assert gateway.completed == []
    assert gateway.failed == []


def test_analysis_worker_completes_validated_result() -> None:
    gateway = FakeAnalysisGateway()
    analyzer = FakeAnalyzer()

    assert process_one_analysis(
        gateway,
        analyzer,
        heartbeat_interval_seconds=3600,
    ) is True

    assert analyzer.preflight_calls == 1
    assert analyzer.calls == 1
    assert gateway.failed == []
    assert len(gateway.completed) == 1
    assert gateway.completed[0].overall_score == 70


def test_analysis_worker_reports_safe_retryable_model_failure() -> None:
    gateway = FakeAnalysisGateway()
    analyzer = FakeAnalyzer(
        analysis_error=OllamaError(
            "ollama_unavailable",
            retryable=True,
        )
    )

    assert process_one_analysis(
        gateway,
        analyzer,
        heartbeat_interval_seconds=3600,
    ) is True

    assert analyzer.preflight_calls == 1
    assert gateway.claim_calls == 1
    assert gateway.completed == []
    assert len(gateway.failed) == 1
    assert gateway.failed[0].code == "ollama_unavailable"
    assert gateway.failed[0].retryable is True


def test_analysis_worker_returns_false_when_queue_is_empty() -> None:
    gateway = FakeAnalysisGateway()

    def empty_claim() -> list[AnalysisJob]:
        gateway.claim_calls += 1
        return []

    gateway.claim = empty_claim

    analyzer = FakeAnalyzer()

    assert process_one_analysis(
        gateway,
        analyzer,
        heartbeat_interval_seconds=3600,
    ) is False

    assert analyzer.preflight_calls == 1
    assert gateway.claim_calls == 1
    assert analyzer.calls == 0
    assert gateway.completed == []
    assert gateway.failed == []