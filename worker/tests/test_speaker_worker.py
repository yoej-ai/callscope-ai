from __future__ import annotations

import json
from pathlib import Path

import httpx
import pytest

import callscope_worker.speaker_worker as speaker_worker
from callscope_worker.core import Settings
from callscope_worker.diarization import (
    DiarizationError,
    DiarizationInterval,
    TranscriptTurn,
)
from callscope_worker.speaker_worker import (
    SpeakerAttributionJob,
    SpeakerGateway,
    SpeakerWorkerError,
    process_one_speaker_attribution,
)


CALL = "20000000-0000-4000-8000-000000000091"
WORKSPACE = "10000000-0000-4000-8000-000000000091"
TOKEN = "60000000-0000-4000-8000-000000000091"


def claim_payload(**overrides: object) -> dict[str, object]:
    value: dict[str, object] = {
        "call_id": CALL,
        "workspace_id": WORKSPACE,
        "storage_bucket": "call-audio",
        "storage_path": f"{WORKSPACE}/{CALL}/source.mp3",
        "content_type": "audio/mpeg",
        "size_bytes": 8,
        "duration_seconds": 3,
        "segments": [
            {"start": 0.0, "end": 1.0, "text": "Hello"},
            {"start": 1.0, "end": 2.0, "text": "Hi there"},
        ],
        "claim_token": TOKEN,
        "attempt_count": 1,
    }
    value.update(overrides)
    return value


def job() -> SpeakerAttributionJob:
    return SpeakerAttributionJob.from_row(claim_payload())


def settings() -> Settings:
    return Settings(
        "https://unit-test.supabase.co",
        "sb_secret_unit_test_not_real",
        False,
        "tiny",
    )


def test_speaker_job_parses_only_bounded_required_claim_data() -> None:
    item = job()
    assert item.call_id == CALL
    assert item.duration_ms == 3_000
    assert [segment.text for segment in item.segments] == ["Hello", "Hi there"]


@pytest.mark.parametrize(
    "override",
    [
        {"call_id": "bad"},
        {"storage_bucket": "public"},
        {"storage_path": "arbitrary.mp3"},
        {"duration_seconds": 0},
        {"segments": []},
        {"attempt_count": 4},
    ],
)
def test_speaker_job_rejects_invalid_or_browser_controlled_claim_data(
    override: dict[str, object],
) -> None:
    with pytest.raises(SpeakerWorkerError):
        SpeakerAttributionJob.from_row(claim_payload(**override))


def test_speaker_gateway_uses_only_narrow_rpcs_and_atomic_turn_payload() -> None:
    seen: list[tuple[str, dict[str, object]]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        payload = json.loads(request.content)
        seen.append((request.url.path, payload))
        if request.url.path.endswith("/claim_speaker_attribution_jobs"):
            return httpx.Response(200, json=[claim_payload()])
        if request.url.path.endswith("/renew_speaker_attribution_lease"):
            return httpx.Response(200, json=True)
        if request.url.path.endswith("/complete_speaker_attribution_job"):
            return httpx.Response(200, json=[{"call_id": CALL, "status": "completed"}])
        if request.url.path.endswith("/fail_speaker_attribution_job"):
            return httpx.Response(200, json=[{"call_id": CALL, "status": "queued"}])
        return httpx.Response(404)

    with httpx.Client(
        base_url="https://unit-test.supabase.co/",
        transport=httpx.MockTransport(handler),
    ) as http:
        gateway = SpeakerGateway(settings(), http=http)
        item = gateway.claim()[0]
        assert gateway.renew(item) is True
        turns = (TranscriptTurn(0, 0, 1000, "Hello", "speaker_1", "agent"),)
        assert gateway.complete(item, turns) is True
        gateway.fail(item, SpeakerWorkerError("diarization_unavailable", retryable=True))

    assert seen[0] == (
        "/rest/v1/rpc/claim_speaker_attribution_jobs",
        {"p_limit": 1},
    )
    assert seen[2][1] == {
        "p_call_id": CALL,
        "p_claim_token": TOKEN,
        "p_turns": [
            {
                "turn_index": 0,
                "start_ms": 0,
                "end_ms": 1000,
                "text": "Hello",
                "speaker_key": "speaker_1",
                "speaker_role": "agent",
            }
        ],
    }


class FakeGateway:
    def __init__(self) -> None:
        self.claim_calls = 0
        self.completed: list[tuple[TranscriptTurn, ...]] = []
        self.failed: list[SpeakerWorkerError] = []

    def claim(self):
        self.claim_calls += 1
        return [job()]

    def renew(self, item):
        return True

    def download(self, item, target: Path):
        target.write_bytes(b"fake")

    def complete(self, item, turns):
        self.completed.append(turns)
        return True

    def fail(self, item, error):
        self.failed.append(error)


class FakeDiarizer:
    def __init__(self, preflight_error: Exception | None = None) -> None:
        self.preflight_error = preflight_error
        self.preflight_calls = 0

    def preflight(self):
        self.preflight_calls += 1
        if self.preflight_error:
            raise self.preflight_error

    def diarize(self, path, *, duration_ms):
        assert duration_ms == 3_000
        return (
            DiarizationInterval(0, 1000, "speaker_1"),
            DiarizationInterval(1000, 2000, "speaker_2"),
        )


class FakeRoleMapper:
    def map_roles(self, turns):
        return {"speaker_1": "agent", "speaker_2": "customer"}


def test_model_preflight_happens_before_database_claim() -> None:
    gateway = FakeGateway()
    diarizer = FakeDiarizer(
        DiarizationError("diarization_model_unavailable", retryable=True)
    )
    with pytest.raises(SpeakerWorkerError):
        process_one_speaker_attribution(
            gateway, diarizer, FakeRoleMapper(), heartbeat_interval_seconds=3600
        )
    assert gateway.claim_calls == 0


def test_worker_aligns_maps_and_completes_without_changing_words(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    gateway = FakeGateway()
    monkeypatch.setattr(speaker_worker, "verify_media_magic", lambda path, mime: None)
    assert process_one_speaker_attribution(
        gateway,
        FakeDiarizer(),
        FakeRoleMapper(),
        heartbeat_interval_seconds=3600,
    ) is True
    assert gateway.failed == []
    assert [[turn.text, turn.speaker_role] for turn in gateway.completed[0]] == [
        ["Hello", "agent"],
        ["Hi there", "customer"],
    ]


def test_diarization_failure_uses_safe_retry_path(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class FailingDiarizer(FakeDiarizer):
        def diarize(self, path, *, duration_ms):
            raise DiarizationError("diarization_engine_failed", retryable=True)

    gateway = FakeGateway()
    monkeypatch.setattr(speaker_worker, "verify_media_magic", lambda path, mime: None)
    assert process_one_speaker_attribution(
        gateway,
        FailingDiarizer(),
        FakeRoleMapper(),
        heartbeat_interval_seconds=3600,
    ) is True
    assert gateway.completed == []
    assert gateway.failed[0].code == "diarization_engine_failed"
