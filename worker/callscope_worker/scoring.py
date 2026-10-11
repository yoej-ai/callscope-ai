"""Shared deterministic scorecard arithmetic.

The model supplies criterion outcomes only. This module owns the Phase 8B/9A
weight semantics and uses Decimal ROUND_HALF_UP arithmetic at two decimals.
"""
from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal, ROUND_HALF_UP
from typing import Mapping


OUTCOMES = frozenset(
    {
        "pass",
        "fail",
        "not_applicable",
        "insufficient_evidence",
    }
)


class ScoringValidationError(ValueError):
    """Safe validation error for deterministic scoring inputs."""


@dataclass(frozen=True)
class WeightedScore:
    overall_score: Decimal | None
    review_required: bool


def calculate_weighted_score(
    criterion_weights: Mapping[str, int],
    outcomes: Mapping[str, str],
) -> WeightedScore:
    """Calculate the canonical score for one exact criterion set."""

    if not 1 <= len(criterion_weights) <= 20:
        raise ScoringValidationError("criterion_weights_invalid")
    if set(outcomes) != set(criterion_weights):
        raise ScoringValidationError("criterion_outcomes_incomplete")

    eligible_weight = 0
    passed_weight = 0
    review_required = False

    for criterion_id, weight in criterion_weights.items():
        if type(weight) is not int or not 1 <= weight <= 100:
            raise ScoringValidationError("criterion_weight_invalid")
        outcome = outcomes[criterion_id]
        if outcome not in OUTCOMES:
            raise ScoringValidationError("criterion_outcome_invalid")
        if outcome in {"pass", "fail"}:
            eligible_weight += weight
            if outcome == "pass":
                passed_weight += weight
        elif outcome == "insufficient_evidence":
            review_required = True

    if eligible_weight == 0:
        return WeightedScore(None, True)

    score = (
        Decimal(passed_weight) * Decimal(100) / Decimal(eligible_weight)
    ).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    return WeightedScore(score, review_required)
