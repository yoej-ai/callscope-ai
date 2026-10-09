"""Local supervisor for the isolated transcription and analysis pipelines.

Each pipeline owns its clients and runs in a separate thread. Failures are
reported only as bounded internal codes, then retried with capped backoff.
The existing one-job functions retain all claim, lease, and completion logic.
"""
from __future__ import annotations

import argparse
import logging
import signal
import threading
from collections.abc import Callable
from dataclasses import dataclass
from types import FrameType
from typing import Protocol

from .analysis_worker import (
    AnalysisGateway,
    AnalysisWorkerError,
    process_one_analysis,
)
from .core import Gateway, Settings, WorkerError, process_one
from .ollama import OllamaAnalyzer, OllamaSettings
from .transcriber import FasterWhisperTranscriber, TranscriptionStartupError


LOG = logging.getLogger("callscope_worker.supervisor")


class PipelineStartupError(Exception):
    """Safe prerequisite/configuration failure for one supervised pipeline."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


class PipelineRuntime(Protocol):
    """Resources and one-job operation owned by one pipeline thread."""

    def process_one(self) -> bool: ...

    def close(self) -> None: ...


class StopSignal(Protocol):
    def is_set(self) -> bool: ...

    def wait(self, timeout: float) -> bool: ...


@dataclass(frozen=True)
class PipelineSpec:
    name: str
    open_runtime: Callable[[], PipelineRuntime]


@dataclass(frozen=True)
class LoopConfig:
    poll_seconds: float = 30.0
    initial_backoff_seconds: float = 5.0
    max_backoff_seconds: float = 60.0

    def __post_init__(self) -> None:
        if self.poll_seconds <= 0:
            raise ValueError("poll interval must be positive")
        if self.initial_backoff_seconds <= 0:
            raise ValueError("initial backoff must be positive")
        if self.max_backoff_seconds < self.initial_backoff_seconds:
            raise ValueError("maximum backoff must not be less than initial backoff")


class _TranscriptionRuntime:
    def __init__(self, gateway: Gateway, transcriber: FasterWhisperTranscriber) -> None:
        self._gateway = gateway
        self._transcriber = transcriber

    @classmethod
    def open(cls) -> "_TranscriptionRuntime":
        try:
            settings = Settings.from_env()
        except ValueError as exc:
            raise PipelineStartupError("worker_configuration_invalid") from exc

        # Model and media prerequisites are loaded before any job can be claimed.
        try:
            transcriber = FasterWhisperTranscriber(settings.model)
        except TranscriptionStartupError as exc:
            raise PipelineStartupError(exc.code) from exc

        return cls(Gateway(settings), transcriber)

    def process_one(self) -> bool:
        return process_one(self._gateway, self._transcriber)

    def close(self) -> None:
        self._gateway.close()


class _AnalysisRuntime:
    def __init__(
        self,
        gateway: AnalysisGateway,
        analyzer: OllamaAnalyzer,
        *,
        heartbeat_interval_seconds: float,
    ) -> None:
        self._gateway = gateway
        self._analyzer = analyzer
        self._heartbeat_interval_seconds = heartbeat_interval_seconds

    @classmethod
    def open(cls, *, heartbeat_interval_seconds: float) -> "_AnalysisRuntime":
        try:
            supabase_settings = Settings.from_env()
        except ValueError as exc:
            raise PipelineStartupError("worker_configuration_invalid") from exc

        try:
            ollama_settings = OllamaSettings.from_env()
        except ValueError as exc:
            raise PipelineStartupError("analysis_configuration_invalid") from exc

        gateway = AnalysisGateway(supabase_settings)
        try:
            analyzer = OllamaAnalyzer(ollama_settings)
        except Exception:
            gateway.close()
            raise
        return cls(
            gateway,
            analyzer,
            heartbeat_interval_seconds=heartbeat_interval_seconds,
        )

    def process_one(self) -> bool:
        return process_one_analysis(
            self._gateway,
            self._analyzer,
            heartbeat_interval_seconds=self._heartbeat_interval_seconds,
        )

    def close(self) -> None:
        try:
            self._analyzer.close()
        finally:
            self._gateway.close()


def _close_runtime(name: str, runtime: PipelineRuntime | None) -> None:
    if runtime is None:
        return
    try:
        runtime.close()
    except Exception:
        LOG.error("Pipeline cleanup failed: pipeline=%s code=cleanup_error", name)


def _wait_after_failure(
    *,
    name: str,
    code: str,
    backoff_seconds: float,
    config: LoopConfig,
    stop: StopSignal,
) -> tuple[float, bool]:
    LOG.warning(
        "Pipeline retry scheduled: pipeline=%s code=%s backoff_seconds=%.1f",
        name,
        code,
        backoff_seconds,
    )
    stopped = stop.wait(backoff_seconds)
    next_backoff = min(config.max_backoff_seconds, backoff_seconds * 2)
    return next_backoff, stopped


def run_pipeline(spec: PipelineSpec, config: LoopConfig, stop: StopSignal) -> None:
    """Run one isolated processing loop until the shared stop signal is set."""

    runtime: PipelineRuntime | None = None
    backoff_seconds = config.initial_backoff_seconds

    try:
        while not stop.is_set():
            if runtime is None:
                try:
                    runtime = spec.open_runtime()
                    backoff_seconds = config.initial_backoff_seconds
                    LOG.info("Pipeline ready: pipeline=%s", spec.name)
                except PipelineStartupError as exc:
                    backoff_seconds, stopped = _wait_after_failure(
                        name=spec.name,
                        code=exc.code,
                        backoff_seconds=backoff_seconds,
                        config=config,
                        stop=stop,
                    )
                    if stopped:
                        break
                    continue
                except (ValueError, RuntimeError):
                    backoff_seconds, stopped = _wait_after_failure(
                        name=spec.name,
                        code="startup_error",
                        backoff_seconds=backoff_seconds,
                        config=config,
                        stop=stop,
                    )
                    if stopped:
                        break
                    continue
                except Exception:
                    backoff_seconds, stopped = _wait_after_failure(
                        name=spec.name,
                        code="unexpected_startup_error",
                        backoff_seconds=backoff_seconds,
                        config=config,
                        stop=stop,
                    )
                    if stopped:
                        break
                    continue

            if stop.is_set():
                break

            try:
                processed = runtime.process_one()
                backoff_seconds = config.initial_backoff_seconds
            except (WorkerError, AnalysisWorkerError) as exc:
                backoff_seconds, stopped = _wait_after_failure(
                    name=spec.name,
                    code=exc.code,
                    backoff_seconds=backoff_seconds,
                    config=config,
                    stop=stop,
                )
                if stopped:
                    break
                continue
            except Exception:
                _close_runtime(spec.name, runtime)
                runtime = None
                backoff_seconds, stopped = _wait_after_failure(
                    name=spec.name,
                    code="unexpected_error",
                    backoff_seconds=backoff_seconds,
                    config=config,
                    stop=stop,
                )
                if stopped:
                    break
                continue

            if not processed and stop.wait(config.poll_seconds):
                break
    finally:
        _close_runtime(spec.name, runtime)
        LOG.info("Pipeline stopped: pipeline=%s", spec.name)


def run_supervisor(
    specs: tuple[PipelineSpec, ...],
    config: LoopConfig,
    stop: threading.Event,
) -> None:
    """Run all pipeline loops and wait until graceful shutdown completes."""

    threads = [
        threading.Thread(
            target=run_pipeline,
            args=(spec, config, stop),
            name=f"callscope-{spec.name}",
        )
        for spec in specs
    ]

    for thread in threads:
        thread.start()

    try:
        while any(thread.is_alive() for thread in threads):
            for thread in threads:
                thread.join(timeout=0.2)
    except KeyboardInterrupt:
        stop.set()
    finally:
        stop.set()
        for thread in threads:
            while thread.is_alive():
                try:
                    thread.join(timeout=0.2)
                except KeyboardInterrupt:
                    stop.set()


def configure_logging() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)


def _install_signal_handlers(stop: threading.Event) -> Callable[[], None]:
    previous: dict[signal.Signals, signal.Handlers] = {}

    def request_shutdown(signum: int, frame: FrameType | None) -> None:
        del signum, frame
        stop.set()

    for signum in (signal.SIGINT, signal.SIGTERM):
        try:
            previous[signum] = signal.getsignal(signum)
            signal.signal(signum, request_shutdown)
        except (OSError, ValueError):
            # Signal registration can be unavailable outside the main thread.
            continue

    def restore() -> None:
        for signum, handler in previous.items():
            signal.signal(signum, handler)

    return restore


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run CallScope transcription and analysis workers together"
    )
    parser.add_argument(
        "--poll-seconds",
        type=float,
        default=30.0,
        help="Idle queue polling interval (default: 30)",
    )
    parser.add_argument(
        "--initial-backoff-seconds",
        type=float,
        default=5.0,
        help="Initial infrastructure retry delay (default: 5)",
    )
    parser.add_argument(
        "--max-backoff-seconds",
        type=float,
        default=60.0,
        help="Maximum infrastructure retry delay (default: 60)",
    )
    parser.add_argument(
        "--analysis-heartbeat-seconds",
        type=float,
        default=60.0,
        help="Analysis lease-renewal interval (default: 60)",
    )
    args = parser.parse_args(argv)

    if not 5 <= args.poll_seconds <= 300:
        parser.error("--poll-seconds must be between 5 and 300")
    if not 1 <= args.initial_backoff_seconds <= 60:
        parser.error("--initial-backoff-seconds must be between 1 and 60")
    if not args.initial_backoff_seconds <= args.max_backoff_seconds <= 300:
        parser.error(
            "--max-backoff-seconds must be between the initial backoff and 300"
        )
    if not 5 <= args.analysis_heartbeat_seconds <= 300:
        parser.error("--analysis-heartbeat-seconds must be between 5 and 300")

    configure_logging()
    config = LoopConfig(
        poll_seconds=args.poll_seconds,
        initial_backoff_seconds=args.initial_backoff_seconds,
        max_backoff_seconds=args.max_backoff_seconds,
    )
    stop = threading.Event()
    restore_signal_handlers = _install_signal_handlers(stop)
    specs = (
        PipelineSpec("transcription", _TranscriptionRuntime.open),
        PipelineSpec(
            "analysis",
            lambda: _AnalysisRuntime.open(
                heartbeat_interval_seconds=args.analysis_heartbeat_seconds
            ),
        ),
    )

    LOG.info("Worker supervisor started")
    try:
        run_supervisor(specs, config, stop)
    finally:
        restore_signal_handlers()
    LOG.info("Worker supervisor stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
