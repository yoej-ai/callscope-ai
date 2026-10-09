"""CLI for the isolated trusted CallScope AI analysis worker."""
from __future__ import annotations

import argparse
import logging
import time

from .analysis_worker import (
    AnalysisGateway,
    AnalysisWorkerError,
    process_one_analysis,
)
from .core import Settings
from .ollama import OllamaAnalyzer, OllamaSettings


LOG = logging.getLogger("callscope_worker.analysis")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="CallScope AI trusted local analysis worker"
    )

    parser.add_argument(
        "--loop",
        action="store_true",
        help="Poll continuously (default: process at most one job)",
    )

    parser.add_argument(
        "--poll-seconds",
        type=int,
        default=30,
        help="Idle delay when --loop is enabled",
    )

    parser.add_argument(
        "--heartbeat-seconds",
        type=float,
        default=60.0,
        help="Analysis lease-renewal interval",
    )

    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s %(message)s",
    )

    if not 5 <= args.poll_seconds <= 300:
        parser.error(
            "--poll-seconds must be between 5 and 300"
        )

    if not 5 <= args.heartbeat_seconds <= 300:
        parser.error(
            "--heartbeat-seconds must be between 5 and 300"
        )

    gateway: AnalysisGateway | None = None
    analyzer: OllamaAnalyzer | None = None

    try:
        supabase_settings = Settings.from_env()
        ollama_settings = OllamaSettings.from_env()

        gateway = AnalysisGateway(
            supabase_settings,
        )

        analyzer = OllamaAnalyzer(
            ollama_settings,
        )

        while True:
            processed = process_one_analysis(
                gateway,
                analyzer,
                heartbeat_interval_seconds=args.heartbeat_seconds,
            )

            if not args.loop:
                LOG.info(
                    "One-job analysis run finished; claimed=%s",
                    processed,
                )
                return 0

            if not processed:
                time.sleep(
                    args.poll_seconds
                )

    except ValueError as exc:
        # Configuration errors contain static validation messages only.
        LOG.error(
            "%s",
            str(exc),
        )
        return 1

    except AnalysisWorkerError as exc:
        LOG.error(
            "Analysis worker cannot access queue: %s",
            exc.code,
        )
        return 1

    except KeyboardInterrupt:
        LOG.info(
            "Analysis worker stopped"
        )
        return 0

    finally:
        if analyzer is not None:
            analyzer.close()

        if gateway is not None:
            gateway.close()


if __name__ == "__main__":
    raise SystemExit(main())