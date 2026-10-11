"""Optional local Ollama smoke test for Phase 9B applicability semantics.

Run manually from worker/ after starting Ollama. This synthetic check is not a
benchmark and is intentionally excluded from normal pytest/CI discovery.
"""
from __future__ import annotations

from uuid import UUID

from callscope_worker.ollama import OllamaSettings
from callscope_worker.scorecard import OllamaScorecardAnalyzer, ScorecardCriterion


CRITERION = ScorecardCriterion(
    criterion_id=str(UUID("40000000-0000-4000-8000-00000000009b")),
    name="Objection Handling",
    description="Evaluate how the agent responds when the customer raises an objection.",
    weight=100,
    pass_guidance="A real objection is acknowledged and answered constructively.",
    fail_guidance="A real objection is dismissed, ignored, or handled incorrectly.",
    position=1,
)

CASES = (
    (
        "no_objection",
        "Agent: Welcome. Customer: I would like to book Tuesday. Agent: Tuesday is available.",
        "not_applicable",
    ),
    (
        "handled_objection",
        "Customer: The price feels too high. Agent: I understand. The fee includes support and we can use the monthly plan. Customer: That resolves my concern.",
        "pass",
    ),
    (
        "mishandled_objection",
        "Customer: The price feels too high. Agent: That is the price, take it or leave it.",
        "fail",
    ),
    (
        "incomplete_exchange",
        "Customer: The price is too high. [The recording is inaudible before the agent response.]",
        "insufficient_evidence",
    ),
)


def main() -> int:
    analyzer = OllamaScorecardAnalyzer(OllamaSettings.from_env())
    try:
        analyzer.preflight()
        failures = 0
        for name, transcript, expected in CASES:
            result = analyzer.analyze(transcript, language="en", criteria=(CRITERION,))
            actual = result.criteria[0].outcome
            print(f"{name}: {actual}")
            failures += actual != expected
        if failures:
            print(f"Applicability smoke mismatches: {failures}/{len(CASES)}")
            return 1
        print("Applicability smoke passed (synthetic local check; not an accuracy claim).")
        return 0
    finally:
        analyzer.close()


if __name__ == "__main__":
    raise SystemExit(main())
