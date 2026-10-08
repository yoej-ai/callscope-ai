from __future__ import annotations

import base64
import json
import subprocess
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import unquote
from uuid import uuid4

import httpx
import pytest

from callscope_worker.core import (
    Gateway,
    Job,
    Settings,
    Transcript,
    WorkerError,
    process_one,
    verify_media_magic,
)
from callscope_worker.transcriber import probe_audio

CALL = "20000000-0000-0000-0000-000000000041"
WORKSPACE = "10000000-0000-0000-0000-000000000041"
TOKEN = "30000000-0000-0000-0000-000000000041"
WAV = b"RIFF" + b"\x00\x00\x00\x00" + b"WAVE" + b"audio-test"
MODERN_SECRET = "sb_secret_unit_test_not_real"
PUBLISHABLE_KEY = "sb_publishable_unit_test_not_real"


def jwt_segment(value: dict[str, object]) -> str:
    encoded = json.dumps(value, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(encoded).rstrip(b"=").decode()


def legacy_jwt(role: str) -> str:
    return ".".join([
        jwt_segment({"alg": "HS256", "typ": "JWT"}),
        jwt_segment({"role": role, "iss": "unit-test"}),
        "not-a-real-signature",
    ])


LEGACY_SERVICE_ROLE_JWT = legacy_jwt("service_role")


@pytest.fixture(autouse=True)
def clear_worker_key_environment(monkeypatch) -> None:
    monkeypatch.delenv("SUPABASE_SECRET_KEY", raising=False)
    monkeypatch.delenv("SUPABASE_SERVICE_ROLE_KEY", raising=False)


def claim_payload(**overrides: object) -> dict[str, object]:
    value: dict[str, object] = {
        "call_id": CALL,
        "workspace_id": WORKSPACE,
        "storage_bucket": "call-audio",
        "storage_path": f"{WORKSPACE}/{CALL}/source.wav",
        "content_type": "audio/wav",
        "size_bytes": len(WAV),
        "claim_token": TOKEN,
        "attempt_count": 1,
    }
    value.update(overrides)
    return value


def job() -> Job:
    return Job.from_row(claim_payload())


def settings() -> Settings:
    return Settings("https://unit-test.supabase.co", MODERN_SECRET, False, "tiny")


def test_claim_validates_exact_private_path_and_mime() -> None:
    assert job().storage_path.endswith("source.wav")
    for invalid in [
        {"storage_bucket": "public"},
        {"storage_path": "../../another-tenant/file.wav"},
        {"storage_path": f"{WORKSPACE}/{CALL}/source.mp3"},
        {"content_type": "text/plain"},
        {"size_bytes": 0},
        {"size_bytes": 26214401},
        {"size_bytes": True},
        {"attempt_count": 4},
        {"claim_token": "bad-token"},
    ]:
        with pytest.raises(WorkerError) as error:
            Job.from_row(claim_payload(**invalid))
        assert error.value.code == "invalid_job"


def test_settings_disallow_insecure_nonlocal_origin_and_empty_key(monkeypatch) -> None:
    monkeypatch.setenv("SUPABASE_SECRET_KEY", MODERN_SECRET)
    monkeypatch.setenv("SUPABASE_URL", "http://remote.example.com")
    with pytest.raises(ValueError):
        Settings.from_env()
    monkeypatch.setenv("SUPABASE_URL", "https://project.supabase.co/anything")
    with pytest.raises(ValueError):
        Settings.from_env()
    monkeypatch.setenv("SUPABASE_URL", "http://127.0.0.1:54321")
    assert Settings.from_env().model == "tiny"
    monkeypatch.delenv("SUPABASE_SECRET_KEY")
    with pytest.raises(ValueError):
        Settings.from_env()


def test_settings_accept_modern_secret_and_legacy_service_role_jwt(monkeypatch) -> None:
    monkeypatch.setenv("SUPABASE_URL", "https://project.supabase.co")
    monkeypatch.setenv("SUPABASE_SECRET_KEY", MODERN_SECRET)
    modern = Settings.from_env()
    assert modern.supabase_key == MODERN_SECRET
    assert modern.use_bearer_auth is False
    assert MODERN_SECRET not in repr(modern)

    monkeypatch.delenv("SUPABASE_SECRET_KEY")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", LEGACY_SERVICE_ROLE_JWT)
    legacy = Settings.from_env()
    assert legacy.supabase_key == LEGACY_SERVICE_ROLE_JWT
    assert legacy.use_bearer_auth is True
    assert LEGACY_SERVICE_ROLE_JWT not in repr(legacy)


def test_gateway_uses_key_type_appropriate_headers() -> None:
    modern = Gateway(settings())
    try:
        assert modern.http.headers["apikey"] == MODERN_SECRET
        assert "authorization" not in modern.http.headers
        assert modern.http.headers["accept-encoding"] == "identity"
    finally:
        modern.close()

    legacy_settings = Settings(
        "https://unit-test.supabase.co", LEGACY_SERVICE_ROLE_JWT, True, "tiny"
    )
    legacy = Gateway(legacy_settings)
    try:
        assert legacy.http.headers["apikey"] == LEGACY_SERVICE_ROLE_JWT
        assert legacy.http.headers["authorization"] == f"Bearer {LEGACY_SERVICE_ROLE_JWT}"
        assert legacy.http.headers["accept-encoding"] == "identity"
    finally:
        legacy.close()


def test_conflicting_key_environment_fails_closed_without_leaking_values(
    monkeypatch, caplog
) -> None:
    monkeypatch.setenv("SUPABASE_URL", "https://project.supabase.co")
    monkeypatch.setenv("SUPABASE_SECRET_KEY", MODERN_SECRET)
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", LEGACY_SERVICE_ROLE_JWT)
    with pytest.raises(ValueError) as error:
        Settings.from_env()
    message = str(error.value)
    assert MODERN_SECRET not in message
    assert LEGACY_SERVICE_ROLE_JWT not in message
    assert MODERN_SECRET not in caplog.text
    assert LEGACY_SERVICE_ROLE_JWT not in caplog.text


@pytest.mark.parametrize(
    "variable,value",
    [
        ("SUPABASE_SECRET_KEY", PUBLISHABLE_KEY),
        ("SUPABASE_SECRET_KEY", "unknown-key"),
        ("SUPABASE_SERVICE_ROLE_KEY", "not-a-jwt"),
        ("SUPABASE_SERVICE_ROLE_KEY", legacy_jwt("anon")),
    ],
)
def test_settings_reject_publishable_malformed_and_non_service_role_keys(
    monkeypatch, variable: str, value: str
) -> None:
    monkeypatch.setenv("SUPABASE_URL", "https://project.supabase.co")
    monkeypatch.setenv(variable, value)
    with pytest.raises(ValueError) as error:
        Settings.from_env()
    assert value not in str(error.value)


def test_gateway_claim_and_download_private_audio_without_logging_secrets(tmp_path, caplog) -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        assert request.headers["apikey"] == MODERN_SECRET
        assert "authorization" not in request.headers
        if request.url.path.endswith("/rpc/claim_transcription_jobs"):
            assert json.loads(request.content) == {"p_limit": 1}
            return httpx.Response(200, json=[claim_payload()])
        if "/storage/v1/object/authenticated/call-audio/" in request.url.path:
            assert unquote(request.url.path).endswith(f"{WORKSPACE}/{CALL}/source.wav")
            return httpx.Response(200, content=WAV)
        return httpx.Response(404)

    with httpx.Client(
        base_url="https://unit-test.supabase.co/",
        headers={"apikey": MODERN_SECRET},
        transport=httpx.MockTransport(handler),
    ) as http:
        gateway = Gateway(settings(), http)
        claimed = gateway.claim()
        assert len(claimed) == 1
        dest = tmp_path / "source.wav"
        gateway.download(claimed[0], dest)
        assert dest.read_bytes() == WAV
        verify_media_magic(dest, "audio/wav")
    assert len(seen) == 2
    assert MODERN_SECRET not in caplog.text


def test_gateway_rejects_oversized_and_short_responses(tmp_path) -> None:
    for body in (WAV + b"extra", WAV[:-2]):
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(200, content=body)

        with httpx.Client(
            base_url="https://unit-test.supabase.co/",
            transport=httpx.MockTransport(handler),
        ) as http:
            with pytest.raises(WorkerError) as error:
                Gateway(settings(), http).download(job(), tmp_path / str(uuid4()))
            assert error.value.code == "audio_size_invalid"
            assert error.value.retryable is False


def test_gateway_worker_rpc_parameters_and_results() -> None:
    methods: list[tuple[str, dict[str, object]]] = []
    def handler(request: httpx.Request) -> httpx.Response:
        methods.append((request.url.path, json.loads(request.content)))
        if request.url.path.endswith("renew_transcription_lease"):
            return httpx.Response(200, json=True)
        if request.url.path.endswith("complete_transcription_job"):
            return httpx.Response(200, json=[{"call_id": CALL, "status": "completed"}])
        return httpx.Response(200, json=[{"call_id": CALL, "status": "queued"}])

    with httpx.Client(base_url="https://unit-test.supabase.co/", transport=httpx.MockTransport(handler)) as http:
        gateway = Gateway(settings(), http)
        assert gateway.renew(job()) is True
        assert gateway.complete(job(), Transcript("hello", "en", [], 2)) is True
        gateway.fail(job(), WorkerError("download_failed", retryable=True))
    assert len(methods) == 3
    assert methods[1][1]["p_transcript_text"] == "hello"
    assert methods[2][1]["p_retryable"] is True
    assert methods[2][1]["p_claim_token"] == TOKEN


def test_signature_validation_fails_closed(tmp_path) -> None:
    audio = tmp_path / "source.wav"
    audio.write_bytes(b"fake audio content")
    with pytest.raises(WorkerError) as exc:
        verify_media_magic(audio, "audio/wav")
    assert exc.value.code == "media_signature_invalid"


def test_transcript_validation_enforces_limits() -> None:
    Transcript("hello", "en", [], 3).validate()
    for transcript in (
        Transcript("", "en", [], 2),
        Transcript("a", "not a code", [], 2),
        Transcript("a", "en", [], -1),
    ):
        with pytest.raises(WorkerError):
            transcript.validate()


class FakeGateway:
    def __init__(self, data: bytes = WAV, *, error: WorkerError | None = None) -> None:
        self.data = data
        self.error = error
        self.claimed = 0
        self.completed: list[Transcript] = []
        self.failed: list[WorkerError] = []

    def claim(self) -> list[Job]:
        self.claimed += 1
        return [job()]

    def renew(self, item: Job) -> bool:
        return True

    def download(self, item: Job, target: Path) -> None:
        if self.error:
            raise self.error
        target.write_bytes(self.data)

    def complete(self, item: Job, transcript: Transcript) -> bool:
        self.completed.append(transcript)
        return True

    def fail(self, item: Job, error: WorkerError) -> None:
        self.failed.append(error)


class FakeTranscriber:
    def __init__(self) -> None:
        self.calls = 0

    def transcribe(self, path: Path) -> Transcript:
        self.calls += 1
        assert path.exists()
        return Transcript("test transcript", "en", [{"start": 0, "end": 1, "text": "test"}], 1)


def test_worker_completes_successfully_and_discards_tempfile() -> None:
    gateway, transcriber = FakeGateway(), FakeTranscriber()
    assert process_one(gateway, transcriber) is True
    assert transcriber.calls == 1
    assert len(gateway.completed) == 1
    assert gateway.failed == []


def test_worker_reports_permanent_media_failure_without_running_engine() -> None:
    gateway, transcriber = FakeGateway(b"wrong"), FakeTranscriber()
    assert process_one(gateway, transcriber) is True
    assert transcriber.calls == 0
    assert gateway.completed == []
    assert [e.code for e in gateway.failed] == ["media_signature_invalid"]
    assert gateway.failed[0].retryable is False


def test_worker_reports_transient_download_error() -> None:
    gateway, transcriber = FakeGateway(error=WorkerError("audio_download_failed", retryable=True)), FakeTranscriber()
    assert process_one(gateway, transcriber) is True
    assert gateway.failed[0].retryable is True


def test_ffprobe_rejects_long_or_non_audio_files(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr("callscope_worker.transcriber.shutil.which", lambda _: "/usr/bin/ffprobe")
    for duration, streams, expected in [
        ("7200", [{"codec_type": "audio"}], "audio_duration_invalid"),
        ("60", [{"codec_type": "video"}], "audio_stream_invalid"),
    ]:
        monkeypatch.setattr(
            "callscope_worker.transcriber.subprocess.run",
            lambda *args, **kwargs: subprocess.CompletedProcess(
                args[0], 0, stdout=json.dumps({"format": {"duration": duration}, "streams": streams})
            ),
        )
        with pytest.raises(WorkerError) as error:
            probe_audio(tmp_path / "example.wav")
        assert error.value.code == expected
