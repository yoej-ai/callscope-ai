"""Command-line entry points for deterministic offline evaluation."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence

from .evaluation import (
    EvaluationValidationError,
    agreement_metrics,
    dataset_summary,
    load_annotations,
    load_dataset,
    load_playbook,
    load_predictions,
    prediction_metrics,
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate and measure offline CallScope evaluation fixtures."
    )
    parser.add_argument("--playbook", required=True, type=Path)
    parser.add_argument("--dataset", required=True, type=Path)
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("validate", help="Validate playbook and dataset files.")

    evaluate = subparsers.add_parser(
        "evaluate", help="Compare a prediction JSONL file with the reference dataset."
    )
    evaluate.add_argument("--predictions", required=True, type=Path)

    agree = subparsers.add_parser(
        "agree", help="Compare two independent reviewer annotation JSONL files."
    )
    agree.add_argument("--reviewer-a", required=True, type=Path)
    agree.add_argument("--reviewer-b", type=Path)
    return parser


def run(arguments: Sequence[str] | None = None) -> dict[str, object]:
    args = _parser().parse_args(arguments)
    playbook = load_playbook(args.playbook)
    cases = load_dataset(args.dataset, playbook)
    if args.command == "validate":
        return {"status": "valid", **dataset_summary(playbook, cases)}
    if args.command == "evaluate":
        predictions = load_predictions(args.predictions, playbook, cases)
        return {
            "status": "ok",
            **prediction_metrics(playbook, cases, predictions),
        }
    reviewer_a = load_annotations(args.reviewer_a, playbook, cases)
    if args.reviewer_b is None:
        return agreement_metrics(playbook, cases, (reviewer_a,))
    reviewer_b = load_annotations(args.reviewer_b, playbook, cases)
    return agreement_metrics(playbook, cases, (reviewer_a, reviewer_b))


def main(arguments: Sequence[str] | None = None) -> int:
    try:
        result = run(arguments)
    except EvaluationValidationError as exc:
        print(json.dumps({"error": str(exc)}, sort_keys=True), file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
