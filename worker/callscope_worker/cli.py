"""Entry point for an intentionally isolated, manually operated worker."""
from __future__ import annotations

import argparse
import logging
import time

from .core import Gateway, Settings, WorkerError, process_one
from .transcriber import FasterWhisperTranscriber

LOG = logging.getLogger("callscope_worker")


def main() -> int:
    parser = argparse.ArgumentParser(description="CallScope AI trusted transcription worker")
    parser.add_argument("--loop", action="store_true", help="Poll continuously (default: one job)")
    parser.add_argument("--poll-seconds", type=int, default=30, help="Idle delay for --loop")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    if args.poll_seconds < 5 or args.poll_seconds > 300:
        parser.error("--poll-seconds must be between 5 and 300")
    try:
        settings = Settings.from_env()
        # Load model BEFORE claiming, so downloads/startup cannot expire the lease.
        transcriber = FasterWhisperTranscriber(settings.model)
    except (ValueError, RuntimeError) as exc:
        # Startup errors carry static messages only, not secret values.
        LOG.error("%s", str(exc))
        return 1

    gateway = Gateway(settings)
    try:
        while True:
            processed = process_one(gateway, transcriber)
            if not args.loop:
                LOG.info("One-job run finished; claimed=%s", processed)
                return 0
            if not processed:
                time.sleep(args.poll_seconds)
    except WorkerError as exc:
        LOG.error("Worker cannot access queue: %s", exc.code)
        return 1
    except KeyboardInterrupt:
        LOG.info("Worker stopped")
        return 0
    finally:
        gateway.close()
