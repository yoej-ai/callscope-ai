from __future__ import annotations

import pytest

from callscope_worker.analysis_worker import AnalysisWorkerError
from callscope_worker.ollama import OllamaSettings
import callscope_worker.analysis_cli as analysis_cli


def test_ollama_settings_from_env_uses_safe_local_defaults(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("OLLAMA_BASE_URL", raising=False)
    monkeypatch.delenv("OLLAMA_MODEL", raising=False)

    settings = OllamaSettings.from_env()

    assert settings.base_url == "http://127.0.0.1:11434"
    assert settings.model == "qwen3:4b-instruct"


def test_ollama_settings_from_env_accepts_explicit_local_values(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv(
        "OLLAMA_BASE_URL",
        "http://localhost:11434",
    )
    monkeypatch.setenv(
        "OLLAMA_MODEL",
        "qwen3:4b-instruct",
    )

    settings = OllamaSettings.from_env()

    assert settings.base_url == "http://localhost:11434"
    assert settings.model == "qwen3:4b-instruct"


def test_ollama_settings_from_env_rejects_remote_origin(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv(
        "OLLAMA_BASE_URL",
        "https://remote.example.com",
    )
    monkeypatch.setenv(
        "OLLAMA_MODEL",
        "qwen3:4b-instruct",
    )

    with pytest.raises(ValueError):
        OllamaSettings.from_env()


def test_analysis_cli_one_job_run_closes_resources(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    events: list[str] = []

    class FakeSupabaseSettings:
        @classmethod
        def from_env(cls):
            events.append("supabase_settings")
            return object()

    class FakeOllamaSettings:
        @classmethod
        def from_env(cls):
            events.append("ollama_settings")
            return object()

    class FakeGateway:
        def __init__(self, settings):
            events.append("gateway_open")

        def close(self) -> None:
            events.append("gateway_close")

    class FakeAnalyzer:
        def __init__(self, settings):
            events.append("analyzer_open")

        def close(self) -> None:
            events.append("analyzer_close")

    def fake_process(
        gateway,
        analyzer,
        *,
        heartbeat_interval_seconds: float = 60.0,
    ) -> bool:
        events.append("process")
        return True

    monkeypatch.setattr(
        analysis_cli,
        "Settings",
        FakeSupabaseSettings,
    )
    monkeypatch.setattr(
        analysis_cli,
        "OllamaSettings",
        FakeOllamaSettings,
    )
    monkeypatch.setattr(
        analysis_cli,
        "AnalysisGateway",
        FakeGateway,
    )
    monkeypatch.setattr(
        analysis_cli,
        "OllamaAnalyzer",
        FakeAnalyzer,
    )
    monkeypatch.setattr(
        analysis_cli,
        "process_one_analysis",
        fake_process,
    )

    assert analysis_cli.main([]) == 0

    assert events == [
        "supabase_settings",
        "ollama_settings",
        "gateway_open",
        "analyzer_open",
        "process",
        "analyzer_close",
        "gateway_close",
    ]


def test_analysis_cli_returns_failure_when_queue_rpc_is_unavailable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class FakeSettings:
        @classmethod
        def from_env(cls):
            return object()

    class FakeGateway:
        def __init__(self, settings):
            pass

        def close(self) -> None:
            pass

    class FakeAnalyzer:
        def __init__(self, settings):
            pass

        def close(self) -> None:
            pass

    def fake_process(
        gateway,
        analyzer,
        *,
        heartbeat_interval_seconds: float = 60.0,
    ) -> bool:
        raise AnalysisWorkerError(
            "analysis_rpc_unavailable",
            retryable=True,
        )

    monkeypatch.setattr(
        analysis_cli,
        "Settings",
        FakeSettings,
    )
    monkeypatch.setattr(
        analysis_cli,
        "OllamaSettings",
        FakeSettings,
    )
    monkeypatch.setattr(
        analysis_cli,
        "AnalysisGateway",
        FakeGateway,
    )
    monkeypatch.setattr(
        analysis_cli,
        "OllamaAnalyzer",
        FakeAnalyzer,
    )
    monkeypatch.setattr(
        analysis_cli,
        "process_one_analysis",
        fake_process,
    )

    assert analysis_cli.main([]) == 1