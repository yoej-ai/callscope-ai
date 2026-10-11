from __future__ import annotations

import logging
import sys
import threading
import tomllib
from pathlib import Path

import pytest

import callscope_worker.cli as transcription_cli
import callscope_worker.supervisor as supervisor
from callscope_worker.analysis_worker import AnalysisLeaseHeartbeat, AnalysisWorkerError
from callscope_worker.core import LeaseHeartbeat, WorkerError
from callscope_worker.scorecard_worker import (
    ScorecardLeaseHeartbeat,
    ScorecardWorkerError,
)
from callscope_worker.supervisor import (
    LoopConfig,
    PipelineSpec,
    run_pipeline,
    run_supervisor,
)


class FakeRuntime:
    def __init__(self, process) -> None:
        self._process = process
        self.closed = False

    def process_one(self) -> bool:
        return self._process()

    def close(self) -> None:
        self.closed = True


class RecordingStop:
    def __init__(self, *, stop_after_waits: int) -> None:
        self.stop_after_waits = stop_after_waits
        self.waits: list[float] = []

    def is_set(self) -> bool:
        return False

    def wait(self, timeout: float) -> bool:
        self.waits.append(timeout)
        return len(self.waits) >= self.stop_after_waits


def test_supervisor_runs_and_closes_all_three_pipelines() -> None:
    stop = threading.Event()
    barrier = threading.Barrier(3)
    processed = {
        "transcription": threading.Event(),
        "analysis": threading.Event(),
        "scorecard": threading.Event(),
    }
    runtimes: dict[str, FakeRuntime] = {}

    def open_runtime(name: str) -> FakeRuntime:
        def process() -> bool:
            barrier.wait(timeout=1.0)
            processed[name].set()
            if all(event.is_set() for event in processed.values()):
                stop.set()
            return False

        runtime = FakeRuntime(process)
        runtimes[name] = runtime
        return runtime

    specs = tuple(
        PipelineSpec(name, lambda name=name: open_runtime(name))
        for name in processed
    )

    run_supervisor(
        specs,
        LoopConfig(
            poll_seconds=30,
            initial_backoff_seconds=1,
            max_backoff_seconds=4,
        ),
        stop,
    )

    assert all(event.is_set() for event in processed.values())
    assert all(runtime.closed for runtime in runtimes.values())


def test_heartbeat_shutdown_waits_for_active_renewal_thread() -> None:
    for heartbeat_class in (
        LeaseHeartbeat,
        AnalysisLeaseHeartbeat,
        ScorecardLeaseHeartbeat,
    ):
        renewal_started = threading.Event()
        release_renewal = threading.Event()

        class BlockingGateway:
            def renew(self, job) -> bool:
                renewal_started.set()
                assert release_renewal.wait(timeout=1.0)
                return True

        heartbeat = heartbeat_class(
            BlockingGateway(),
            object(),
            interval_seconds=0.01,
        )
        heartbeat.start()
        assert renewal_started.wait(timeout=1.0)

        stopper = threading.Thread(target=heartbeat.stop)
        stopper.start()
        assert stopper.is_alive()

        release_renewal.set()
        stopper.join(timeout=1.0)

        assert not stopper.is_alive()
        assert not heartbeat._thread.is_alive()


def test_empty_queue_waits_for_poll_interval_instead_of_busy_looping() -> None:
    calls = 0

    def process() -> bool:
        nonlocal calls
        calls += 1
        return False

    runtime = FakeRuntime(process)
    stop = RecordingStop(stop_after_waits=1)

    run_pipeline(
        PipelineSpec("transcription", lambda: runtime),
        LoopConfig(
            poll_seconds=30,
            initial_backoff_seconds=1,
            max_backoff_seconds=4,
        ),
        stop,
    )

    assert calls == 1
    assert stop.waits == [30]
    assert runtime.closed is True


def test_transcription_startup_reports_safe_configuration_code(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sensitive_message = "configuration contained private credential material"

    def invalid_settings():
        raise ValueError(sensitive_message)

    monkeypatch.setattr(
        supervisor.Settings,
        "from_env",
        staticmethod(invalid_settings),
    )

    with pytest.raises(supervisor.PipelineStartupError) as error:
        supervisor._TranscriptionRuntime.open()

    assert error.value.code == "worker_configuration_invalid"
    assert sensitive_message not in str(error.value)


def test_analysis_startup_reports_analysis_specific_configuration_code(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sensitive_message = "invalid local model URL with private material"
    monkeypatch.setattr(
        supervisor.Settings,
        "from_env",
        staticmethod(lambda: object()),
    )

    def invalid_ollama_settings():
        raise ValueError(sensitive_message)

    monkeypatch.setattr(
        supervisor.OllamaSettings,
        "from_env",
        staticmethod(invalid_ollama_settings),
    )

    with pytest.raises(supervisor.PipelineStartupError) as error:
        supervisor._AnalysisRuntime.open(heartbeat_interval_seconds=60)

    assert error.value.code == "analysis_configuration_invalid"
    assert sensitive_message not in str(error.value)


def test_scorecard_startup_reports_scorecard_specific_configuration_code(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sensitive_message = "invalid local scorecard model URL with private material"
    monkeypatch.setattr(
        supervisor.Settings,
        "from_env",
        staticmethod(lambda: object()),
    )

    def invalid_ollama_settings():
        raise ValueError(sensitive_message)

    monkeypatch.setattr(
        supervisor.OllamaSettings,
        "from_env",
        staticmethod(invalid_ollama_settings),
    )

    with pytest.raises(supervisor.PipelineStartupError) as error:
        supervisor._ScorecardRuntime.open(heartbeat_interval_seconds=60)

    assert error.value.code == "scorecard_configuration_invalid"
    assert sensitive_message not in str(error.value)


@pytest.mark.parametrize(
    ("failing_pipeline", "failure"),
    [
        (
            "analysis",
            AnalysisWorkerError("ollama_unavailable", retryable=True),
        ),
        (
            "transcription",
            WorkerError("rpc_unavailable", retryable=True),
        ),
        (
            "scorecard",
            ScorecardWorkerError("scorecard_rpc_unavailable", retryable=True),
        ),
    ],
)
def test_pipeline_infrastructure_failure_does_not_stop_other_pipeline(
    failing_pipeline: str,
    failure: Exception,
) -> None:
    stop = threading.Event()
    failure_seen = threading.Event()
    healthy_seen = threading.Event()
    runtimes: list[FakeRuntime] = []

    def open_failing() -> FakeRuntime:
        def process() -> bool:
            failure_seen.set()
            raise failure

        runtime = FakeRuntime(process)
        runtimes.append(runtime)
        return runtime

    def open_healthy() -> FakeRuntime:
        def process() -> bool:
            assert failure_seen.wait(timeout=1.0)
            healthy_seen.set()
            stop.set()
            return True

        runtime = FakeRuntime(process)
        runtimes.append(runtime)
        return runtime

    healthy_pipeline = (
        "transcription" if failing_pipeline == "analysis" else "analysis"
    )
    specs = (
        PipelineSpec(failing_pipeline, open_failing),
        PipelineSpec(healthy_pipeline, open_healthy),
    )

    run_supervisor(
        specs,
        LoopConfig(
            poll_seconds=30,
            initial_backoff_seconds=0.01,
            max_backoff_seconds=0.02,
        ),
        stop,
    )

    assert failure_seen.is_set()
    assert healthy_seen.is_set()
    assert all(runtime.closed for runtime in runtimes)


def test_repeated_infrastructure_failures_use_capped_backoff() -> None:
    calls = 0

    def process() -> bool:
        nonlocal calls
        calls += 1
        raise WorkerError("rpc_unavailable", retryable=True)

    runtime = FakeRuntime(process)
    stop = RecordingStop(stop_after_waits=4)

    run_pipeline(
        PipelineSpec("transcription", lambda: runtime),
        LoopConfig(
            poll_seconds=30,
            initial_backoff_seconds=1,
            max_backoff_seconds=4,
        ),
        stop,
    )

    assert calls == 4
    assert stop.waits == [1, 2, 4, 4]
    assert runtime.closed is True


def test_unexpected_error_log_is_bounded_and_does_not_expose_message(
    caplog: pytest.LogCaptureFixture,
) -> None:
    sensitive_message = "private transcript and credential material"
    runtime = FakeRuntime(
        lambda: (_ for _ in ()).throw(RuntimeError(sensitive_message))
    )
    stop = RecordingStop(stop_after_waits=1)
    caplog.set_level(logging.INFO, logger="callscope_worker.supervisor")

    run_pipeline(
        PipelineSpec("analysis", lambda: runtime),
        LoopConfig(
            poll_seconds=30,
            initial_backoff_seconds=1,
            max_backoff_seconds=4,
        ),
        stop,
    )

    assert "pipeline=analysis" in caplog.text
    assert "code=unexpected_error" in caplog.text
    assert sensitive_message not in caplog.text
    assert runtime.closed is True


def test_existing_transcription_one_shot_cli_still_closes_resources(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    events: list[str] = []

    class FakeSettings:
        model = "tiny"

        @classmethod
        def from_env(cls):
            events.append("settings")
            return cls()

    class FakeTranscriber:
        def __init__(self, model: str) -> None:
            assert model == "tiny"
            events.append("transcriber")

    class FakeGateway:
        def __init__(self, settings) -> None:
            events.append("gateway_open")

        def close(self) -> None:
            events.append("gateway_close")

    def fake_process(gateway, transcriber) -> bool:
        events.append("process")
        return True

    monkeypatch.setattr(transcription_cli, "Settings", FakeSettings)
    monkeypatch.setattr(transcription_cli, "FasterWhisperTranscriber", FakeTranscriber)
    monkeypatch.setattr(transcription_cli, "Gateway", FakeGateway)
    monkeypatch.setattr(transcription_cli, "process_one", fake_process)
    monkeypatch.setattr(sys, "argv", ["callscope-transcribe"])

    assert transcription_cli.main() == 0
    assert events == [
        "settings",
        "transcriber",
        "gateway_open",
        "process",
        "gateway_close",
    ]


def test_cli_entry_points_include_supervisor_and_preserve_one_shot_commands() -> None:
    pyproject_path = Path(__file__).parents[1] / "pyproject.toml"
    with pyproject_path.open("rb") as pyproject_file:
        scripts = tomllib.load(pyproject_file)["project"]["scripts"]

    assert scripts == {
        "callscope-worker": "callscope_worker.supervisor:main",
        "callscope-transcribe": "callscope_worker.cli:main",
        "callscope-analyze": "callscope_worker.analysis_cli:main",
    }
