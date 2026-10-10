from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from callscope_worker.evaluation import (
    AnnotationRecord,
    CriterionLabel,
    EvaluationValidationError,
    PredictionLabel,
    PredictionRecord,
    ReviewerMetadata,
    agreement_metrics,
    dataset_summary,
    load_dataset,
    load_playbook,
    load_predictions,
    prediction_metrics,
    reference_score,
    validate_case,
)
from callscope_worker import evaluation_cli


ROOT = Path(__file__).resolve().parents[2]
PLAYBOOK_PATH = ROOT / "evals" / "playbooks" / "sales_v1.json"
DATASET_PATH = ROOT / "evals" / "datasets" / "sales_v1.jsonl"


@pytest.fixture(scope="module")
def playbook():
    return load_playbook(PLAYBOOK_PATH)


@pytest.fixture(scope="module")
def cases(playbook):
    return load_dataset(DATASET_PATH, playbook)


def first_case_payload() -> dict[str, object]:
    return json.loads(DATASET_PATH.read_text(encoding="utf-8").splitlines()[0])


def write_jsonl(path: Path, values: list[object]) -> None:
    path.write_text(
        "\n".join(json.dumps(value, ensure_ascii=False) for value in values) + "\n",
        encoding="utf-8",
    )


def test_valid_dataset_is_accepted(playbook, cases) -> None:
    assert len(cases) == 30
    assert cases[0].case_id == "sales-en-001"


def test_duplicate_case_id_is_rejected(tmp_path: Path, playbook) -> None:
    case = first_case_payload()
    path = tmp_path / "duplicates.jsonl"
    write_jsonl(path, [case, case])
    with pytest.raises(EvaluationValidationError, match="case_id_duplicate"):
        load_dataset(path, playbook)


@pytest.mark.parametrize(
    ("mutation", "error"),
    [
        (lambda case: case["labels"][0].update(outcome="maybe"), "outcome_invalid"),
        (
            lambda case: case["labels"][0].update(criterion_id="unknown"),
            "criterion_unknown",
        ),
        (lambda case: case["transcript"][0].update(text="   "), "transcript_text_invalid"),
        (
            lambda case: case["transcript"][1].update(
                turn_id=case["transcript"][0]["turn_id"]
            ),
            "turn_id_invalid",
        ),
        (
            lambda case: case["labels"][0].update(evidence_turn_ids=["t999"]),
            "evidence_turn_unknown",
        ),
        (lambda case: case.update(language="taglish"), "language_invalid"),
        (lambda case: case.update(synthetic=False), "provenance_invalid"),
        (
            lambda case: case.update(
                annotation={
                    "label_source": "human",
                    "reviewer_alias": "Real Person Name",
                }
            ),
            "reviewer_metadata_invalid",
        ),
        (
            lambda case: case.update(reference_overall_score=99),
            "reference_score_inconsistent",
        ),
        (
            lambda case: case.update(review_needed=True),
            "review_needed_inconsistent",
        ),
    ],
)
def test_dataset_contract_rejects_invalid_cases(playbook, mutation, error) -> None:
    case = first_case_payload()
    mutation(case)
    with pytest.raises(EvaluationValidationError, match=error):
        validate_case(case, playbook)


def test_duplicate_criterion_label_is_rejected(playbook) -> None:
    case = first_case_payload()
    case["labels"][1] = copy.deepcopy(case["labels"][0])
    with pytest.raises(EvaluationValidationError, match="criterion_label_duplicate"):
        validate_case(case, playbook)


def test_possible_secret_in_dataset_file_is_rejected(tmp_path: Path, playbook) -> None:
    case = first_case_payload()
    case["transcript"][0]["text"] = "sb_" + "secret_" + "abcdefghijklmnopqrstuvwxyz"
    path = tmp_path / "secret.jsonl"
    write_jsonl(path, [case])
    with pytest.raises(EvaluationValidationError, match="possible_secret_detected"):
        load_dataset(path, playbook)


def test_possible_personal_identifier_in_dataset_is_rejected(
    tmp_path: Path, playbook
) -> None:
    case = first_case_payload()
    case["transcript"][0]["text"] = "Contact " + "person" + "@" + "example.com"
    path = tmp_path / "personal-data.jsonl"
    write_jsonl(path, [case])
    with pytest.raises(
        EvaluationValidationError, match="possible_sensitive_data_detected"
    ):
        load_dataset(path, playbook)


def test_invalid_calendar_timestamp_is_rejected(playbook) -> None:
    case = first_case_payload()
    case["annotation"] = {
        "label_source": "synthetic_reference",
        "reviewer_alias": "fixture-author",
        "reviewed_at": "2026-99-99T00:00:00Z",
    }
    with pytest.raises(EvaluationValidationError, match="reviewer_metadata_invalid"):
        validate_case(case, playbook)


def labels(playbook, outcomes: dict[str, str]) -> tuple[CriterionLabel, ...]:
    return tuple(
        CriterionLabel(
            criterion.criterion_id,
            outcomes.get(criterion.criterion_id, "fail"),
            "Observable test rationale.",
            (),
        )
        for criterion in playbook.criteria
    )


def test_reference_score_all_pass_is_100(playbook) -> None:
    value, review_needed, complete = reference_score(
        playbook,
        labels(playbook, {criterion.criterion_id: "pass" for criterion in playbook.criteria}),
    )
    assert value == 100.0
    assert review_needed is False
    assert complete is True


def test_reference_score_all_fail_is_zero(playbook) -> None:
    value, review_needed, complete = reference_score(playbook, labels(playbook, {}))
    assert value == 0.0
    assert review_needed is False
    assert complete is True


def test_reference_score_uses_weights_and_deterministic_rounding(playbook) -> None:
    value, _, _ = reference_score(
        playbook,
        labels(
            playbook,
            {
                "greeting": "pass",
                "discovery": "pass",
                "qualification": "fail",
                "objection_handling": "fail",
                "closing": "fail",
                "clear_next_step": "fail",
            },
        ),
    )
    assert value == 35.0

    rounded, _, _ = reference_score(
        playbook,
        labels(
            playbook,
            {
                "greeting": "pass",
                "discovery": "pass",
                "qualification": "fail",
                "objection_handling": "not_applicable",
                "closing": "fail",
                "clear_next_step": "fail",
            },
        ),
    )
    assert rounded == 41.18


def test_reference_score_excludes_not_applicable(playbook) -> None:
    value, review_needed, complete = reference_score(
        playbook,
        labels(
            playbook,
            {
                "greeting": "pass",
                "discovery": "fail",
                "qualification": "not_applicable",
                "objection_handling": "not_applicable",
                "closing": "not_applicable",
                "clear_next_step": "not_applicable",
            },
        ),
    )
    assert value == 28.57
    assert review_needed is False
    assert complete is True


def test_reference_score_marks_insufficient_evidence_for_review(playbook) -> None:
    value, review_needed, complete = reference_score(
        playbook,
        labels(
            playbook,
            {
                "greeting": "pass",
                "discovery": "insufficient_evidence",
                "qualification": "fail",
                "objection_handling": "not_applicable",
                "closing": "not_applicable",
                "clear_next_step": "not_applicable",
            },
        ),
    )
    assert value == 33.33
    assert review_needed is True
    assert complete is False


def test_reference_score_no_eligible_criteria_is_null(playbook) -> None:
    value, review_needed, complete = reference_score(
        playbook,
        labels(
            playbook,
            {criterion.criterion_id: "not_applicable" for criterion in playbook.criteria},
        ),
    )
    assert value is None
    assert review_needed is True
    assert complete is False


def annotation_for(case, alias: str, outcomes: dict[str, str]) -> AnnotationRecord:
    return AnnotationRecord(
        case.case_id,
        "sales_v1",
        f"{case.case_id}-{alias}",
        tuple(
            CriterionLabel(
                label.criterion_id,
                outcomes.get(label.criterion_id, label.outcome),
                "Observable reviewer rationale.",
                label.evidence_turn_ids,
            )
            for label in case.labels
        ),
        ReviewerMetadata("human", alias, "2026-10-10T00:00:00Z"),
    )


def test_agreement_metrics_perfect_and_language_segmented(playbook, cases) -> None:
    selected = (cases[0], cases[10], cases[20])
    reviewer_a = tuple(annotation_for(case, "reviewer-a", {}) for case in selected)
    reviewer_b = tuple(annotation_for(case, "reviewer-b", {}) for case in selected)
    result = agreement_metrics(playbook, selected, (reviewer_a, reviewer_b))
    assert result["overall_agreement"] == 1.0
    assert result["cohen_kappa"] == 1.0
    assert result["per_criterion"]["greeting"]["agreement"] == 1.0
    assert result["per_language"]["en"]["comparisons"] == 6
    assert result["per_language"]["fil"]["agreement"] == 1.0
    assert result["per_language"]["en-fil"]["agreement"] == 1.0


def test_agreement_metrics_report_partial_disagreement(playbook, cases) -> None:
    case = cases[0]
    reviewer_a = (annotation_for(case, "reviewer-a", {}),)
    reviewer_b = (
        annotation_for(case, "reviewer-b", {"greeting": "fail"}),
    )
    result = agreement_metrics(playbook, (case,), (reviewer_a, reviewer_b))
    assert result["overall_agreement"] == pytest.approx(0.8333)
    assert result["per_criterion"]["greeting"]["agreement"] == 0.0
    assert result["per_criterion"]["discovery"]["agreement"] == 1.0
    assert result["cohen_kappa"] is not None


def test_agreement_handles_missing_reviewer_and_undefined_kappa(playbook, cases) -> None:
    missing = agreement_metrics(playbook, (cases[0],), ((),))
    assert missing["status"] == "insufficient_reviewers"
    assert missing["cohen_kappa"] is None
    assert missing["kappa_status"] == "requires_two_reviewers"

    one_class_a = (
        annotation_for(
            cases[0],
            "reviewer-a",
            {criterion.criterion_id: "pass" for criterion in playbook.criteria},
        ),
    )
    one_class_b = (
        annotation_for(
            cases[0],
            "reviewer-b",
            {criterion.criterion_id: "pass" for criterion in playbook.criteria},
        ),
    )
    undefined = agreement_metrics(
        playbook, (cases[0],), (one_class_a, one_class_b)
    )
    assert undefined["cohen_kappa"] is None
    assert undefined["kappa_status"] == "undefined_single_class"


def test_agreement_rejects_comparing_a_reviewer_with_self(playbook, cases) -> None:
    annotation = (annotation_for(cases[0], "reviewer-a", {}),)
    with pytest.raises(EvaluationValidationError, match="reviewers_not_independent"):
        agreement_metrics(playbook, (cases[0],), (annotation, annotation))


def perfect_prediction(case) -> PredictionRecord:
    return PredictionRecord(
        case.case_id,
        "sales_v1",
        tuple(PredictionLabel(label.criterion_id, label.outcome) for label in case.labels),
        case.reference_overall_score,
        case.review_needed,
    )


def test_prediction_metrics_perfect(playbook, cases) -> None:
    selected = cases[:3]
    result = prediction_metrics(
        playbook, selected, tuple(perfect_prediction(case) for case in selected)
    )
    assert result["criterion_accuracy"] == 1.0
    assert result["coverage"] == 1.0
    assert result["macro_precision"] == 1.0
    assert result["macro_recall"] == 1.0
    assert result["macro_f1"] == 1.0
    assert result["overall_score_mae"] == 0.0
    assert result["review_needed_accuracy"] == 1.0


def test_prediction_metrics_include_incorrect_and_missing_predictions(playbook, cases) -> None:
    case_a, case_b = cases[0], cases[1]
    labels_a = list(perfect_prediction(case_a).criteria)
    labels_a[0] = PredictionLabel("greeting", "fail")
    partial = PredictionRecord(
        case_a.case_id,
        "sales_v1",
        tuple(labels_a[:-1]),
        90.0,
        not case_a.review_needed,
    )
    result = prediction_metrics(playbook, (case_a, case_b), (partial,))
    assert result["expected_criterion_labels"] == 12
    assert result["predicted_criterion_labels"] == 5
    assert result["missing_criterion_predictions"] == 7
    assert result["missing_prediction_cases"] == 1
    assert result["criterion_accuracy"] == pytest.approx(4 / 12, abs=0.0001)
    assert result["confusion_matrix"]["pass"]["fail"] == 1
    assert result["confusion_matrix"]["pass"]["__missing__"] >= 1
    assert result["overall_score_mae"] == 10.0
    assert result["review_needed_accuracy"] == 0.0
    assert result["macro_precision"] == pytest.approx(0.6667)
    assert result["macro_recall"] == pytest.approx(0.2778)
    assert result["macro_f1"] == pytest.approx(0.3889)
    assert result["per_criterion_accuracy"]["greeting"]["total"] == 2
    assert result["per_language_accuracy"]["en"]["total"] == 12


def test_unknown_prediction_case_is_rejected(tmp_path: Path, playbook, cases) -> None:
    prediction = {
        "schema_version": "eval_prediction.v1",
        "case_id": "unknown-case",
        "playbook_fixture_id": "sales_v1",
        "criteria": [],
        "overall_score": None,
        "review_needed": True,
    }
    path = tmp_path / "predictions.jsonl"
    write_jsonl(path, [prediction])
    with pytest.raises(EvaluationValidationError, match="prediction_case_unknown"):
        load_predictions(path, playbook, cases)


def test_unknown_prediction_criterion_is_rejected(
    tmp_path: Path, playbook, cases
) -> None:
    prediction = {
        "schema_version": "eval_prediction.v1",
        "case_id": cases[0].case_id,
        "playbook_fixture_id": "sales_v1",
        "criteria": [{"criterion_id": "unknown", "outcome": "pass"}],
        "overall_score": None,
        "review_needed": True,
    }
    path = tmp_path / "predictions.jsonl"
    write_jsonl(path, [prediction])
    with pytest.raises(EvaluationValidationError, match="prediction_criterion_unknown"):
        load_predictions(path, playbook, cases)


def test_cli_validate_is_deterministic_and_invalid_input_is_nonzero(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    arguments = [
        "--playbook",
        str(PLAYBOOK_PATH),
        "--dataset",
        str(DATASET_PATH),
        "validate",
    ]
    assert evaluation_cli.main(arguments) == 0
    first = capsys.readouterr().out
    assert evaluation_cli.main(arguments) == 0
    second = capsys.readouterr().out
    assert first == second

    bad = tmp_path / "bad.jsonl"
    bad.write_text("not-json\n", encoding="utf-8")
    assert evaluation_cli.main(
        [
            "--playbook",
            str(PLAYBOOK_PATH),
            "--dataset",
            str(bad),
            "validate",
        ]
    ) == 2
    assert "jsonl_invalid_1" in capsys.readouterr().err


def test_cli_evaluates_a_valid_partial_prediction_file(
    tmp_path: Path, cases, capsys: pytest.CaptureFixture[str]
) -> None:
    case = cases[0]
    prediction = {
        "schema_version": "eval_prediction.v1",
        "case_id": case.case_id,
        "playbook_fixture_id": "sales_v1",
        "criteria": [
            {"criterion_id": label.criterion_id, "outcome": label.outcome}
            for label in case.labels
        ],
        "overall_score": case.reference_overall_score,
        "review_needed": case.review_needed,
    }
    path = tmp_path / "predictions.jsonl"
    write_jsonl(path, [prediction])
    assert evaluation_cli.main(
        [
            "--playbook",
            str(PLAYBOOK_PATH),
            "--dataset",
            str(DATASET_PATH),
            "evaluate",
            "--predictions",
            str(path),
        ]
    ) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["prediction_case_count"] == 1
    assert report["missing_prediction_cases"] == 29
    assert report["coverage"] == pytest.approx(1 / 30, abs=0.0001)


def test_cli_compares_independent_human_annotation_files(
    tmp_path: Path, cases, capsys: pytest.CaptureFixture[str]
) -> None:
    case = cases[0]

    def record(alias: str) -> dict[str, object]:
        return {
            "schema_version": "eval_annotation.v1",
            "case_id": case.case_id,
            "playbook_fixture_id": "sales_v1",
            "annotation_id": f"{case.case_id}-{alias}",
            "labels": [
                {
                    "criterion_id": label.criterion_id,
                    "outcome": label.outcome,
                    "rationale": "Observable independent reviewer rationale.",
                    "evidence_turn_ids": list(label.evidence_turn_ids),
                }
                for label in case.labels
            ],
            "reviewer": {
                "label_source": "human",
                "reviewer_alias": alias,
                "reviewed_at": "2026-10-10T00:00:00Z",
            },
        }

    reviewer_a = tmp_path / "reviewer-a.jsonl"
    reviewer_b = tmp_path / "reviewer-b.jsonl"
    write_jsonl(reviewer_a, [record("reviewer-a")])
    write_jsonl(reviewer_b, [record("reviewer-b")])
    assert evaluation_cli.main(
        [
            "--playbook",
            str(PLAYBOOK_PATH),
            "--dataset",
            str(DATASET_PATH),
            "agree",
            "--reviewer-a",
            str(reviewer_a),
            "--reviewer-b",
            str(reviewer_b),
        ]
    ) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["overall_agreement"] == 1.0
    assert report["reviewers"] == ["reviewer-a", "reviewer-b"]


def test_dataset_coverage_is_balanced_and_explicitly_synthetic(playbook, cases) -> None:
    summary = dataset_summary(playbook, cases)
    assert summary["case_count"] == 30
    assert summary["language_counts"] == {"en": 10, "fil": 10, "en-fil": 10}
    assert summary["synthetic_case_count"] == 30
    assert all(count > 0 for count in summary["outcome_counts"].values())
    assert set(summary["criterion_coverage"]) == {
        criterion.criterion_id for criterion in playbook.criteria
    }
    assert all(count == 30 for count in summary["criterion_coverage"].values())
    assert all(case.provenance == "synthetic_reference" for case in cases)
    assert all(case.annotation.label_source == "synthetic_reference" for case in cases)
