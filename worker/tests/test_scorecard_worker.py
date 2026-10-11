from __future__ import annotations

import json

import httpx
import pytest

from callscope_worker.core import Settings
from callscope_worker.ollama import OllamaError
from callscope_worker.scorecard import CriterionOutcome, ScorecardModelResult
from callscope_worker.scorecard_worker import (
    ScorecardGateway,
    ScorecardJob,
    ScorecardWorkerError,
    process_one_scorecard,
)
from test_scorecard import CRITERION_ONE, CRITERION_TWO, criteria_payload


SCORECARD = "50000000-0000-4000-8000-000000000091"
CALL = "20000000-0000-4000-8000-000000000091"
WORKSPACE = "10000000-0000-4000-8000-000000000091"
VERSION = "30000000-0000-4000-8000-000000000091"
TOKEN = "60000000-0000-4000-8000-000000000091"
MODERN_SECRET = "sb_secret_unit_test_not_real"


def claim_payload(**overrides: object) -> dict[str, object]:
    value: dict[str, object] = {
        "scorecard_id": SCORECARD,
        "call_id": CALL,
        "workspace_id": WORKSPACE,
        "playbook_version_id": VERSION,
        "transcript_text": "Customer asked about pricing.",
        "language_code": "en",
        "criteria": criteria_payload(),
        "claim_token": TOKEN,
        "attempt_count": 1,
    }
    value.update(overrides)
    return value


def job() -> ScorecardJob:
    return ScorecardJob.from_row(claim_payload())


def result() -> ScorecardModelResult:
    return ScorecardModelResult(
        (
            CriterionOutcome(CRITERION_ONE, "pass"),
            CriterionOutcome(CRITERION_TWO, "fail"),
        )
    )


def settings() -> Settings:
    return Settings(
        "https://unit-test.supabase.co",
        MODERN_SECRET,
        False,
        "tiny",
    )


def test_scorecard_job_validates_bounded_claim() -> None:
    item = job()
    assert item.scorecard_id == SCORECARD
    assert item.playbook_version_id == VERSION
    assert len(item.criteria) == 2


@pytest.mark.parametrize(
    "override",
    [
        {"scorecard_id": "bad"},
        {"playbook_version_id": "bad"},
        {"transcript_text": ""},
        {"criteria": []},
        {"attempt_count": 4},
    ],
)
def test_scorecard_job_rejects_invalid_claim(override: dict[str, object]) -> None:
    with pytest.raises(ScorecardWorkerError):
        ScorecardJob.from_row(claim_payload(**override))


def test_scorecard_gateway_uses_only_narrow_rpcs() -> None:
    seen: list[tuple[str, dict[str, object]]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        payload = json.loads(request.content)
        seen.append((request.url.path, payload))
        if request.url.path.endswith("/claim_scorecard_jobs"):
            return httpx.Response(200, json=[claim_payload()])
        if request.url.path.endswith("/renew_scorecard_lease"):
            return httpx.Response(200, json=True)
        if request.url.path.endswith("/complete_scorecard_job"):
            return httpx.Response(
                200,
                json=[{"scorecard_id": SCORECARD, "status": "completed"}],
            )
        if request.url.path.endswith("/fail_scorecard_job"):
            return httpx.Response(
                200,
                json=[{"scorecard_id": SCORECARD, "status": "queued"}],
            )
        return httpx.Response(404)

    with httpx.Client(
        base_url="https://unit-test.supabase.co/",
        transport=httpx.MockTransport(handler),
    ) as http:
        gateway = ScorecardGateway(settings(), http=http)
        item = gateway.claim()[0]
        assert gateway.renew(item) is True
        assert gateway.complete(item, result()) is True
        gateway.fail(item, ScorecardWorkerError("ollama_unavailable", retryable=True))

    assert seen[0] == ("/rest/v1/rpc/claim_scorecard_jobs", {"p_limit": 1})
    assert seen[2][1] == {
        "p_scorecard_id": SCORECARD,
        "p_claim_token": TOKEN,
        "p_criteria": [
            {"criterion_id": CRITERION_ONE, "outcome": "pass"},
            {"criterion_id": CRITERION_TWO, "outcome": "fail"},
        ],
    }


class FakeGateway:
    def __init__(self) -> None:
        self.claim_calls = 0
        self.completed: list[ScorecardModelResult] = []
        self.failed: list[ScorecardWorkerError] = []

    def claim(self) -> list[ScorecardJob]:
        self.claim_calls += 1
        return [job()]

    def renew(self, item: ScorecardJob) -> bool:
        return True

    def complete(self, item: ScorecardJob, value: ScorecardModelResult) -> bool:
        self.completed.append(value)
        return True

    def fail(self, item: ScorecardJob, error: ScorecardWorkerError) -> None:
        self.failed.append(error)


class FakeAnalyzer:
    def __init__(self, error: Exception | None = None) -> None:
        self.error = error
        self.preflight_calls = 0
        self.analyze_calls = 0

    def preflight(self) -> None:
        self.preflight_calls += 1
        if self.error:
            raise self.error

    def analyze(self, transcript, *, language, criteria):
        self.analyze_calls += 1
        return result()


def test_scorecard_worker_preflights_then_completes() -> None:
    gateway = FakeGateway()
    analyzer = FakeAnalyzer()
    assert process_one_scorecard(
        gateway, analyzer, heartbeat_interval_seconds=3600
    ) is True
    assert analyzer.preflight_calls == 1
    assert gateway.claim_calls == 1
    assert len(gateway.completed) == 1
    assert gateway.failed == []


def test_scorecard_preflight_failure_never_claims() -> None:
    gateway = FakeGateway()
    analyzer = FakeAnalyzer(OllamaError("ollama_unavailable", retryable=True))
    with pytest.raises(ScorecardWorkerError):
        process_one_scorecard(gateway, analyzer, heartbeat_interval_seconds=3600)
    assert gateway.claim_calls == 0


def test_scorecard_model_failure_uses_safe_retry_path() -> None:
    class FailingAnalyzer(FakeAnalyzer):
        def analyze(self, transcript, *, language, criteria):
            raise OllamaError("ollama_output_invalid", retryable=True)

    gateway = FakeGateway()
    assert process_one_scorecard(
        gateway, FailingAnalyzer(), heartbeat_interval_seconds=3600
    ) is True
    assert gateway.completed == []
    assert gateway.failed[0].code == "ollama_output_invalid"
