"""Deterministic, offline evaluation contracts for future scorecard models.

This module never calls a model, network service, or production database. All
inputs are untrusted repository/local files and are validated before metrics
are calculated. Reviewer rationales are short evidence summaries, never
chain-of-thought.
"""
from __future__ import annotations

import json
import math
import re
from collections import Counter
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path
from typing import Iterable, Mapping, Sequence


PLAYBOOK_SCHEMA_VERSION = "eval_playbook.v1"
CASE_SCHEMA_VERSION = "eval_case.v1"
ANNOTATION_SCHEMA_VERSION = "eval_annotation.v1"
PREDICTION_SCHEMA_VERSION = "eval_prediction.v1"
OUTCOMES = ("pass", "fail", "not_applicable", "insufficient_evidence")
LANGUAGES = ("en", "fil", "en-fil")
LABEL_SOURCES = ("synthetic_reference", "human")

MAX_FILE_BYTES = 10_000_000
MAX_CASES = 10_000
MAX_TURNS = 500
MAX_TURN_TEXT = 20_000
MAX_TRANSCRIPT_TEXT = 1_000_000
MAX_RATIONALE = 500
MAX_NOTES = 1_000
MAX_CRITERIA = 20

IDENTIFIER_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,99}$")
TURN_ID_RE = re.compile(r"^t[0-9]{3,6}$")
REVIEWER_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
TIMESTAMP_RE = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
)
SECRET_PATTERNS = (
    re.compile(r"sb_secret_[A-Za-z0-9_-]{8,}"),
    re.compile(r"sk-[A-Za-z0-9_-]{20,}"),
    re.compile(r"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}"),
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
)
SENSITIVE_DATA_PATTERNS = (
    re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"),
    re.compile(r"\b(?:\d[ -]?){8,}\d\b"),
)


class EvaluationValidationError(ValueError):
    """Safe machine-readable validation error without raw input content."""


@dataclass(frozen=True)
class Criterion:
    criterion_id: str
    name: str
    description: str
    weight: int
    pass_guidance: str
    fail_guidance: str
    position: int


@dataclass(frozen=True)
class EvaluationPlaybook:
    fixture_id: str
    name: str
    vertical: str
    criteria: tuple[Criterion, ...]

    @property
    def criteria_by_id(self) -> dict[str, Criterion]:
        return {criterion.criterion_id: criterion for criterion in self.criteria}


@dataclass(frozen=True)
class ReviewerMetadata:
    label_source: str
    reviewer_alias: str
    reviewed_at: str | None = None
    notes: str | None = None


@dataclass(frozen=True)
class CriterionLabel:
    criterion_id: str
    outcome: str
    rationale: str
    evidence_turn_ids: tuple[str, ...]
    annotation: ReviewerMetadata | None = None


@dataclass(frozen=True)
class TranscriptTurn:
    turn_id: str
    text: str
    speaker_role: str | None


@dataclass(frozen=True)
class EvaluationCase:
    case_id: str
    provenance: str
    synthetic: bool
    scenario: str
    language: str
    transcript: tuple[TranscriptTurn, ...]
    labels: tuple[CriterionLabel, ...]
    reference_overall_score: float | None
    review_needed: bool
    annotation: ReviewerMetadata

    @property
    def labels_by_id(self) -> dict[str, CriterionLabel]:
        return {label.criterion_id: label for label in self.labels}


@dataclass(frozen=True)
class AnnotationRecord:
    case_id: str
    playbook_fixture_id: str
    annotation_id: str
    labels: tuple[CriterionLabel, ...]
    reviewer: ReviewerMetadata

    @property
    def labels_by_id(self) -> dict[str, CriterionLabel]:
        return {label.criterion_id: label for label in self.labels}


@dataclass(frozen=True)
class PredictionLabel:
    criterion_id: str
    outcome: str


@dataclass(frozen=True)
class PredictionRecord:
    case_id: str
    playbook_fixture_id: str
    criteria: tuple[PredictionLabel, ...]
    overall_score: float | None
    review_needed: bool

    @property
    def criteria_by_id(self) -> dict[str, PredictionLabel]:
        return {label.criterion_id: label for label in self.criteria}


def _require_mapping(value: object, code: str) -> Mapping[str, object]:
    if not isinstance(value, Mapping):
        raise EvaluationValidationError(code)
    return value


def _require_exact_fields(
    value: Mapping[str, object], expected: set[str], code: str
) -> None:
    if set(value) != expected:
        raise EvaluationValidationError(code)


def _string(
    value: object,
    *,
    code: str,
    maximum: int,
    minimum: int = 1,
    multiline: bool = False,
) -> str:
    if not isinstance(value, str):
        raise EvaluationValidationError(code)
    normalized = value.strip()
    if not minimum <= len(normalized) <= maximum:
        raise EvaluationValidationError(code)
    forbidden = "\x00\r" if multiline else "\x00\r\n\t"
    if any(character in normalized for character in forbidden):
        raise EvaluationValidationError(code)
    return normalized


def _identifier(value: object, code: str) -> str:
    normalized = _string(value, code=code, maximum=100)
    if not IDENTIFIER_RE.fullmatch(normalized):
        raise EvaluationValidationError(code)
    return normalized


def _score(value: object, code: str) -> float | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise EvaluationValidationError(code)
    numeric = float(value)
    if not math.isfinite(numeric) or not 0 <= numeric <= 100:
        raise EvaluationValidationError(code)
    return numeric


def _metadata(value: object, *, synthetic: bool | None = None) -> ReviewerMetadata:
    item = _require_mapping(value, "reviewer_metadata_invalid")
    allowed = {"label_source", "reviewer_alias", "reviewed_at", "notes"}
    if not {"label_source", "reviewer_alias"}.issubset(item) or set(item) - allowed:
        raise EvaluationValidationError("reviewer_metadata_invalid")
    source = _string(
        item["label_source"], code="reviewer_metadata_invalid", maximum=30
    )
    alias = _string(
        item["reviewer_alias"], code="reviewer_metadata_invalid", maximum=64
    )
    if source not in LABEL_SOURCES or not REVIEWER_RE.fullmatch(alias):
        raise EvaluationValidationError("reviewer_metadata_invalid")
    reviewed_at_value = item.get("reviewed_at")
    reviewed_at = None
    if reviewed_at_value is not None:
        reviewed_at = _string(
            reviewed_at_value, code="reviewer_metadata_invalid", maximum=20
        )
        if not TIMESTAMP_RE.fullmatch(reviewed_at):
            raise EvaluationValidationError("reviewer_metadata_invalid")
        try:
            datetime.strptime(reviewed_at, "%Y-%m-%dT%H:%M:%SZ")
        except ValueError as exc:
            raise EvaluationValidationError("reviewer_metadata_invalid") from exc
    notes_value = item.get("notes")
    notes = None
    if notes_value is not None:
        notes = _string(
            notes_value,
            code="reviewer_metadata_invalid",
            maximum=MAX_NOTES,
            minimum=0,
            multiline=True,
        )
    if source == "human" and reviewed_at is None:
        raise EvaluationValidationError("reviewer_metadata_invalid")
    if synthetic is True and source != "synthetic_reference":
        raise EvaluationValidationError("provenance_invalid")
    if synthetic is False and source != "human":
        raise EvaluationValidationError("provenance_invalid")
    return ReviewerMetadata(source, alias, reviewed_at, notes)


def validate_playbook(payload: object) -> EvaluationPlaybook:
    item = _require_mapping(payload, "playbook_invalid")
    _require_exact_fields(
        item,
        {"schema_version", "fixture_id", "name", "vertical", "criteria"},
        "playbook_fields_invalid",
    )
    if item["schema_version"] != PLAYBOOK_SCHEMA_VERSION:
        raise EvaluationValidationError("playbook_schema_version_invalid")
    fixture_id = _identifier(item["fixture_id"], "playbook_fixture_id_invalid")
    name = _string(item["name"], code="playbook_name_invalid", maximum=120)
    vertical = _identifier(item["vertical"], "playbook_vertical_invalid")
    raw_criteria = item["criteria"]
    if not isinstance(raw_criteria, list) or not 1 <= len(raw_criteria) <= MAX_CRITERIA:
        raise EvaluationValidationError("playbook_criteria_invalid")
    criteria: list[Criterion] = []
    ids: set[str] = set()
    names: set[str] = set()
    for raw in raw_criteria:
        criterion = _require_mapping(raw, "playbook_criterion_invalid")
        _require_exact_fields(
            criterion,
            {
                "criterion_id",
                "name",
                "description",
                "weight",
                "pass_guidance",
                "fail_guidance",
                "position",
            },
            "playbook_criterion_fields_invalid",
        )
        criterion_id = _identifier(
            criterion["criterion_id"], "playbook_criterion_id_invalid"
        )
        criterion_name = _string(
            criterion["name"], code="playbook_criterion_name_invalid", maximum=120
        )
        weight = criterion["weight"]
        position = criterion["position"]
        if type(weight) is not int or not 1 <= weight <= 100:
            raise EvaluationValidationError("playbook_criterion_weight_invalid")
        if type(position) is not int or not 1 <= position <= MAX_CRITERIA:
            raise EvaluationValidationError("playbook_criterion_position_invalid")
        if criterion_id in ids or criterion_name.casefold() in names:
            raise EvaluationValidationError("playbook_criterion_duplicate")
        ids.add(criterion_id)
        names.add(criterion_name.casefold())
        criteria.append(
            Criterion(
                criterion_id,
                criterion_name,
                _string(
                    criterion["description"],
                    code="playbook_criterion_description_invalid",
                    maximum=1_000,
                    multiline=True,
                ),
                weight,
                _string(
                    criterion["pass_guidance"],
                    code="playbook_pass_guidance_invalid",
                    maximum=2_000,
                    multiline=True,
                ),
                _string(
                    criterion["fail_guidance"],
                    code="playbook_fail_guidance_invalid",
                    maximum=2_000,
                    multiline=True,
                ),
                position,
            )
        )
    criteria.sort(key=lambda value: value.position)
    if [criterion.position for criterion in criteria] != list(
        range(1, len(criteria) + 1)
    ):
        raise EvaluationValidationError("playbook_criterion_positions_invalid")
    if sum(criterion.weight for criterion in criteria) != 100:
        raise EvaluationValidationError("playbook_weight_total_invalid")
    return EvaluationPlaybook(fixture_id, name, vertical, tuple(criteria))


def _labels(
    value: object,
    *,
    playbook: EvaluationPlaybook,
    turn_ids: set[str] | None,
    require_all: bool,
) -> tuple[CriterionLabel, ...]:
    if not isinstance(value, list) or len(value) > len(playbook.criteria):
        raise EvaluationValidationError("criterion_labels_invalid")
    labels: list[CriterionLabel] = []
    seen: set[str] = set()
    for raw in value:
        item = _require_mapping(raw, "criterion_label_invalid")
        required = {"criterion_id", "outcome", "rationale", "evidence_turn_ids"}
        if not required.issubset(item) or set(item) - (required | {"annotation"}):
            raise EvaluationValidationError("criterion_label_fields_invalid")
        criterion_id = _identifier(item["criterion_id"], "criterion_id_invalid")
        if criterion_id not in playbook.criteria_by_id:
            raise EvaluationValidationError("criterion_unknown")
        if criterion_id in seen:
            raise EvaluationValidationError("criterion_label_duplicate")
        seen.add(criterion_id)
        outcome = _string(item["outcome"], code="outcome_invalid", maximum=30)
        if outcome not in OUTCOMES:
            raise EvaluationValidationError("outcome_invalid")
        rationale = _string(
            item["rationale"],
            code="rationale_invalid",
            maximum=MAX_RATIONALE,
            multiline=True,
        )
        raw_evidence = item["evidence_turn_ids"]
        if not isinstance(raw_evidence, list) or len(raw_evidence) > MAX_TURNS:
            raise EvaluationValidationError("evidence_invalid")
        evidence: list[str] = []
        for raw_turn_id in raw_evidence:
            turn_id = _string(raw_turn_id, code="evidence_invalid", maximum=7)
            if not TURN_ID_RE.fullmatch(turn_id) or turn_id in evidence:
                raise EvaluationValidationError("evidence_invalid")
            if turn_ids is not None and turn_id not in turn_ids:
                raise EvaluationValidationError("evidence_turn_unknown")
            evidence.append(turn_id)
        label_annotation = (
            _metadata(item["annotation"]) if "annotation" in item else None
        )
        labels.append(
            CriterionLabel(
                criterion_id, outcome, rationale, tuple(evidence), label_annotation
            )
        )
    if require_all and seen != set(playbook.criteria_by_id):
        raise EvaluationValidationError("criterion_labels_incomplete")
    labels.sort(key=lambda label: playbook.criteria_by_id[label.criterion_id].position)
    return tuple(labels)


def reference_score(
    playbook: EvaluationPlaybook,
    labels: Sequence[CriterionLabel],
) -> tuple[float | None, bool, bool]:
    """Return score, review-needed, and completeness using fixed weight rules."""

    by_id = {label.criterion_id: label for label in labels}
    if set(by_id) != set(playbook.criteria_by_id):
        raise EvaluationValidationError("criterion_labels_incomplete")
    eligible_weight = 0
    passed_weight = 0
    has_insufficient = False
    for criterion in playbook.criteria:
        outcome = by_id[criterion.criterion_id].outcome
        if outcome in {"pass", "fail"}:
            eligible_weight += criterion.weight
            if outcome == "pass":
                passed_weight += criterion.weight
        elif outcome == "insufficient_evidence":
            has_insufficient = True
        elif outcome != "not_applicable":
            raise EvaluationValidationError("outcome_invalid")
    if eligible_weight == 0:
        return None, True, False
    value = (
        Decimal(passed_weight) * Decimal(100) / Decimal(eligible_weight)
    ).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    review_needed = has_insufficient
    return float(value), review_needed, not review_needed


def validate_case(payload: object, playbook: EvaluationPlaybook) -> EvaluationCase:
    item = _require_mapping(payload, "case_invalid")
    _require_exact_fields(
        item,
        {
            "schema_version",
            "case_id",
            "provenance",
            "synthetic",
            "scenario",
            "language",
            "transcript",
            "labels",
            "reference_overall_score",
            "review_needed",
            "annotation",
        },
        "case_fields_invalid",
    )
    if item["schema_version"] != CASE_SCHEMA_VERSION:
        raise EvaluationValidationError("case_schema_version_invalid")
    case_id = _identifier(item["case_id"], "case_id_invalid")
    provenance = _string(
        item["provenance"], code="provenance_invalid", maximum=30
    )
    synthetic = item["synthetic"]
    if type(synthetic) is not bool:
        raise EvaluationValidationError("provenance_invalid")
    if (synthetic and provenance != "synthetic_reference") or (
        not synthetic and provenance != "human"
    ):
        raise EvaluationValidationError("provenance_invalid")
    scenario = _identifier(item["scenario"], "scenario_invalid")
    language = _string(item["language"], code="language_invalid", maximum=10)
    if language not in LANGUAGES:
        raise EvaluationValidationError("language_invalid")
    raw_transcript = item["transcript"]
    if not isinstance(raw_transcript, list) or not 1 <= len(raw_transcript) <= MAX_TURNS:
        raise EvaluationValidationError("transcript_invalid")
    transcript: list[TranscriptTurn] = []
    turn_ids: set[str] = set()
    total_text = 0
    for raw in raw_transcript:
        turn = _require_mapping(raw, "transcript_turn_invalid")
        if set(turn) not in (
            {"turn_id", "text"},
            {"turn_id", "text", "speaker_role"},
        ):
            raise EvaluationValidationError("transcript_turn_fields_invalid")
        turn_id = _string(turn["turn_id"], code="turn_id_invalid", maximum=7)
        if not TURN_ID_RE.fullmatch(turn_id) or turn_id in turn_ids:
            raise EvaluationValidationError("turn_id_invalid")
        text = _string(
            turn["text"],
            code="transcript_text_invalid",
            maximum=MAX_TURN_TEXT,
            multiline=True,
        )
        total_text += len(text)
        if total_text > MAX_TRANSCRIPT_TEXT:
            raise EvaluationValidationError("transcript_too_large")
        role_value = turn.get("speaker_role")
        role = None
        if role_value is not None:
            role = _string(role_value, code="speaker_role_invalid", maximum=20)
            if role not in {"agent", "customer", "unknown"}:
                raise EvaluationValidationError("speaker_role_invalid")
        turn_ids.add(turn_id)
        transcript.append(TranscriptTurn(turn_id, text, role))
    labels = _labels(
        item["labels"], playbook=playbook, turn_ids=turn_ids, require_all=True
    )
    reference = _score(item["reference_overall_score"], "reference_score_invalid")
    review_needed = item["review_needed"]
    if type(review_needed) is not bool:
        raise EvaluationValidationError("review_needed_invalid")
    calculated_score, calculated_review, _ = reference_score(playbook, labels)
    if reference != calculated_score:
        raise EvaluationValidationError("reference_score_inconsistent")
    if review_needed != calculated_review:
        raise EvaluationValidationError("review_needed_inconsistent")
    annotation = _metadata(item["annotation"], synthetic=synthetic)
    if any(
        label.annotation is not None
        and label.annotation.label_source != annotation.label_source
        for label in labels
    ):
        raise EvaluationValidationError("provenance_invalid")
    return EvaluationCase(
        case_id,
        provenance,
        synthetic,
        scenario,
        language,
        tuple(transcript),
        labels,
        reference,
        review_needed,
        annotation,
    )


def _read_text(path: Path) -> str:
    try:
        size = path.stat().st_size
        if not 1 <= size <= MAX_FILE_BYTES:
            raise EvaluationValidationError("file_size_invalid")
        raw = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise EvaluationValidationError("file_unreadable") from exc
    if any(pattern.search(raw) for pattern in SECRET_PATTERNS):
        raise EvaluationValidationError("possible_secret_detected")
    if any(pattern.search(raw) for pattern in SENSITIVE_DATA_PATTERNS):
        raise EvaluationValidationError("possible_sensitive_data_detected")
    return raw


def _json_lines(path: Path) -> list[object]:
    raw = _read_text(path)
    values: list[object] = []
    for line_number, line in enumerate(raw.splitlines(), start=1):
        if not line.strip():
            raise EvaluationValidationError(f"jsonl_blank_line_{line_number}")
        try:
            values.append(json.loads(line))
        except json.JSONDecodeError as exc:
            raise EvaluationValidationError(f"jsonl_invalid_{line_number}") from exc
    if not values or len(values) > MAX_CASES:
        raise EvaluationValidationError("jsonl_record_count_invalid")
    return values


def load_playbook(path: Path) -> EvaluationPlaybook:
    try:
        payload = json.loads(_read_text(path))
    except json.JSONDecodeError as exc:
        raise EvaluationValidationError("playbook_json_invalid") from exc
    return validate_playbook(payload)


def load_dataset(path: Path, playbook: EvaluationPlaybook) -> tuple[EvaluationCase, ...]:
    cases: list[EvaluationCase] = []
    case_ids: set[str] = set()
    for payload in _json_lines(path):
        case = validate_case(payload, playbook)
        if case.case_id in case_ids:
            raise EvaluationValidationError("case_id_duplicate")
        case_ids.add(case.case_id)
        cases.append(case)
    return tuple(cases)


def validate_annotation(
    payload: object,
    playbook: EvaluationPlaybook,
    cases_by_id: Mapping[str, EvaluationCase],
) -> AnnotationRecord:
    item = _require_mapping(payload, "annotation_invalid")
    _require_exact_fields(
        item,
        {
            "schema_version",
            "case_id",
            "playbook_fixture_id",
            "annotation_id",
            "labels",
            "reviewer",
        },
        "annotation_fields_invalid",
    )
    if item["schema_version"] != ANNOTATION_SCHEMA_VERSION:
        raise EvaluationValidationError("annotation_schema_version_invalid")
    case_id = _identifier(item["case_id"], "annotation_case_id_invalid")
    if case_id not in cases_by_id:
        raise EvaluationValidationError("annotation_case_unknown")
    if item["playbook_fixture_id"] != playbook.fixture_id:
        raise EvaluationValidationError("annotation_playbook_invalid")
    annotation_id = _identifier(item["annotation_id"], "annotation_id_invalid")
    turn_ids = {turn.turn_id for turn in cases_by_id[case_id].transcript}
    labels = _labels(
        item["labels"], playbook=playbook, turn_ids=turn_ids, require_all=False
    )
    reviewer = _metadata(item["reviewer"])
    if any(
        label.annotation is not None
        and (
            label.annotation.label_source != reviewer.label_source
            or label.annotation.reviewer_alias != reviewer.reviewer_alias
        )
        for label in labels
    ):
        raise EvaluationValidationError("reviewer_metadata_invalid")
    return AnnotationRecord(
        case_id, playbook.fixture_id, annotation_id, labels, reviewer
    )


def load_annotations(
    path: Path,
    playbook: EvaluationPlaybook,
    cases: Sequence[EvaluationCase],
) -> tuple[AnnotationRecord, ...]:
    by_case = {case.case_id: case for case in cases}
    records: list[AnnotationRecord] = []
    annotation_ids: set[str] = set()
    case_ids: set[str] = set()
    file_reviewer: str | None = None
    file_source: str | None = None
    for payload in _json_lines(path):
        record = validate_annotation(payload, playbook, by_case)
        if file_reviewer is None:
            file_reviewer = record.reviewer.reviewer_alias
            file_source = record.reviewer.label_source
        if (
            record.reviewer.reviewer_alias != file_reviewer
            or record.reviewer.label_source != file_source
        ):
            raise EvaluationValidationError("annotation_reviewer_mixed")
        if record.annotation_id in annotation_ids or record.case_id in case_ids:
            raise EvaluationValidationError("annotation_duplicate")
        annotation_ids.add(record.annotation_id)
        case_ids.add(record.case_id)
        records.append(record)
    return tuple(records)


def validate_prediction(
    payload: object,
    playbook: EvaluationPlaybook,
    case_ids: set[str],
) -> PredictionRecord:
    item = _require_mapping(payload, "prediction_invalid")
    _require_exact_fields(
        item,
        {
            "schema_version",
            "case_id",
            "playbook_fixture_id",
            "criteria",
            "overall_score",
            "review_needed",
        },
        "prediction_fields_invalid",
    )
    if item["schema_version"] != PREDICTION_SCHEMA_VERSION:
        raise EvaluationValidationError("prediction_schema_version_invalid")
    case_id = _identifier(item["case_id"], "prediction_case_id_invalid")
    if case_id not in case_ids:
        raise EvaluationValidationError("prediction_case_unknown")
    if item["playbook_fixture_id"] != playbook.fixture_id:
        raise EvaluationValidationError("prediction_playbook_invalid")
    raw_criteria = item["criteria"]
    if not isinstance(raw_criteria, list) or len(raw_criteria) > len(playbook.criteria):
        raise EvaluationValidationError("prediction_criteria_invalid")
    criteria: list[PredictionLabel] = []
    seen: set[str] = set()
    for raw in raw_criteria:
        criterion = _require_mapping(raw, "prediction_criterion_invalid")
        _require_exact_fields(
            criterion,
            {"criterion_id", "outcome"},
            "prediction_criterion_fields_invalid",
        )
        criterion_id = _identifier(
            criterion["criterion_id"], "prediction_criterion_id_invalid"
        )
        if criterion_id not in playbook.criteria_by_id:
            raise EvaluationValidationError("prediction_criterion_unknown")
        if criterion_id in seen:
            raise EvaluationValidationError("prediction_criterion_duplicate")
        seen.add(criterion_id)
        outcome = _string(
            criterion["outcome"], code="prediction_outcome_invalid", maximum=30
        )
        if outcome not in OUTCOMES:
            raise EvaluationValidationError("prediction_outcome_invalid")
        criteria.append(PredictionLabel(criterion_id, outcome))
    score = _score(item["overall_score"], "prediction_score_invalid")
    review_needed = item["review_needed"]
    if type(review_needed) is not bool:
        raise EvaluationValidationError("prediction_review_needed_invalid")
    criteria.sort(key=lambda value: playbook.criteria_by_id[value.criterion_id].position)
    return PredictionRecord(
        case_id, playbook.fixture_id, tuple(criteria), score, review_needed
    )


def load_predictions(
    path: Path,
    playbook: EvaluationPlaybook,
    cases: Sequence[EvaluationCase],
) -> tuple[PredictionRecord, ...]:
    case_ids = {case.case_id for case in cases}
    records: list[PredictionRecord] = []
    seen: set[str] = set()
    for payload in _json_lines(path):
        record = validate_prediction(payload, playbook, case_ids)
        if record.case_id in seen:
            raise EvaluationValidationError("prediction_case_duplicate")
        seen.add(record.case_id)
        records.append(record)
    return tuple(records)


def _rounded(value: float | None) -> float | None:
    if value is None:
        return None
    return float(Decimal(str(value)).quantize(Decimal("0.0001"), rounding=ROUND_HALF_UP))


def dataset_summary(
    playbook: EvaluationPlaybook, cases: Sequence[EvaluationCase]
) -> dict[str, object]:
    languages = Counter(case.language for case in cases)
    outcomes = Counter(label.outcome for case in cases for label in case.labels)
    criteria = Counter(label.criterion_id for case in cases for label in case.labels)
    return {
        "case_count": len(cases),
        "criterion_coverage": {
            criterion.criterion_id: criteria[criterion.criterion_id]
            for criterion in playbook.criteria
        },
        "language_counts": {key: languages[key] for key in LANGUAGES},
        "outcome_counts": {key: outcomes[key] for key in OUTCOMES},
        "playbook_fixture_id": playbook.fixture_id,
        "schema_version": CASE_SCHEMA_VERSION,
        "synthetic_case_count": sum(case.synthetic for case in cases),
    }


def agreement_metrics(
    playbook: EvaluationPlaybook,
    cases: Sequence[EvaluationCase],
    annotation_sets: Sequence[Sequence[AnnotationRecord]],
) -> dict[str, object]:
    if len(annotation_sets) < 2:
        return {
            "status": "insufficient_reviewers",
            "overall_agreement": None,
            "cohen_kappa": None,
            "kappa_status": "requires_two_reviewers",
            "comparable_labels": 0,
            "missing_labels": len(cases) * len(playbook.criteria),
            "per_criterion": {},
            "per_language": {},
        }
    left_records, right_records = annotation_sets[0], annotation_sets[1]
    left_reviewers = {record.reviewer.reviewer_alias for record in left_records}
    right_reviewers = {record.reviewer.reviewer_alias for record in right_records}
    if left_reviewers & right_reviewers:
        raise EvaluationValidationError("reviewers_not_independent")
    left = {record.case_id: record for record in left_records}
    right = {record.case_id: record for record in right_records}
    case_by_id = {case.case_id: case for case in cases}
    pairs: list[tuple[str, str, str, str]] = []
    missing = 0
    for case in sorted(cases, key=lambda value: value.case_id):
        left_labels = left.get(case.case_id)
        right_labels = right.get(case.case_id)
        left_by_id = left_labels.labels_by_id if left_labels else {}
        right_by_id = right_labels.labels_by_id if right_labels else {}
        for criterion in playbook.criteria:
            left_label = left_by_id.get(criterion.criterion_id)
            right_label = right_by_id.get(criterion.criterion_id)
            if left_label is None or right_label is None:
                missing += 1
                continue
            pairs.append(
                (
                    criterion.criterion_id,
                    case.language,
                    left_label.outcome,
                    right_label.outcome,
                )
            )
    def group(values: Iterable[tuple[str, str]]) -> dict[str, object]:
        items = list(values)
        if not items:
            return {"agreement": None, "agreements": 0, "comparisons": 0}
        agreements = sum(left_value == right_value for left_value, right_value in items)
        return {
            "agreement": _rounded(agreements / len(items)),
            "agreements": agreements,
            "comparisons": len(items),
        }
    overall = group((left_value, right_value) for _, _, left_value, right_value in pairs)
    per_criterion = {
        criterion.criterion_id: group(
            (left_value, right_value)
            for criterion_id, _, left_value, right_value in pairs
            if criterion_id == criterion.criterion_id
        )
        for criterion in playbook.criteria
    }
    per_language = {
        language: group(
            (left_value, right_value)
            for _, pair_language, left_value, right_value in pairs
            if pair_language == language
        )
        for language in LANGUAGES
    }
    if not pairs:
        kappa = None
        kappa_status = "no_comparable_labels"
    else:
        count = len(pairs)
        left_counts = Counter(left_value for _, _, left_value, _ in pairs)
        right_counts = Counter(right_value for _, _, _, right_value in pairs)
        expected = sum(
            (left_counts[outcome] / count) * (right_counts[outcome] / count)
            for outcome in OUTCOMES
        )
        if math.isclose(expected, 1.0):
            kappa = None
            kappa_status = "undefined_single_class"
        else:
            observed = sum(
                left_value == right_value for _, _, left_value, right_value in pairs
            ) / count
            kappa = _rounded((observed - expected) / (1 - expected))
            kappa_status = "ok"
    reviewer_aliases = sorted(
        {
            record.reviewer.reviewer_alias
            for records in annotation_sets[:2]
            for record in records
        }
    )
    return {
        "status": "ok",
        "reviewers": reviewer_aliases,
        "overall_agreement": overall["agreement"],
        "agreements": overall["agreements"],
        "comparable_labels": overall["comparisons"],
        "missing_labels": missing,
        "per_criterion": per_criterion,
        "per_language": per_language,
        "cohen_kappa": kappa,
        "kappa_status": kappa_status,
    }


def prediction_metrics(
    playbook: EvaluationPlaybook,
    cases: Sequence[EvaluationCase],
    predictions: Sequence[PredictionRecord],
) -> dict[str, object]:
    predictions_by_case = {record.case_id: record for record in predictions}
    expected_labels = len(cases) * len(playbook.criteria)
    correct = 0
    present = 0
    missing_labels = 0
    confusion: dict[str, Counter[str]] = {
        outcome: Counter() for outcome in OUTCOMES
    }
    per_criterion_counts: dict[str, list[int]] = {
        criterion.criterion_id: [0, 0] for criterion in playbook.criteria
    }
    per_language_counts: dict[str, list[int]] = {
        language: [0, 0] for language in LANGUAGES
    }
    score_errors: list[float] = []
    missing_scores = 0
    review_correct = 0
    missing_cases = 0
    for case in sorted(cases, key=lambda value: value.case_id):
        prediction = predictions_by_case.get(case.case_id)
        if prediction is None:
            missing_cases += 1
            missing_labels += len(playbook.criteria)
            missing_scores += case.reference_overall_score is not None
            for label in case.labels:
                confusion[label.outcome]["__missing__"] += 1
                per_criterion_counts[label.criterion_id][1] += 1
                per_language_counts[case.language][1] += 1
            continue
        predicted_by_id = prediction.criteria_by_id
        review_correct += prediction.review_needed == case.review_needed
        for gold in case.labels:
            per_criterion_counts[gold.criterion_id][1] += 1
            per_language_counts[case.language][1] += 1
            predicted = predicted_by_id.get(gold.criterion_id)
            if predicted is None:
                missing_labels += 1
                confusion[gold.outcome]["__missing__"] += 1
                continue
            present += 1
            confusion[gold.outcome][predicted.outcome] += 1
            if predicted.outcome == gold.outcome:
                correct += 1
                per_criterion_counts[gold.criterion_id][0] += 1
                per_language_counts[case.language][0] += 1
        if case.reference_overall_score is None or prediction.overall_score is None:
            if case.reference_overall_score is not None:
                missing_scores += 1
        else:
            score_errors.append(abs(prediction.overall_score - case.reference_overall_score))
    class_metrics: dict[str, dict[str, float | int | None]] = {}
    macro_precision_values: list[float] = []
    macro_recall_values: list[float] = []
    macro_f1_values: list[float] = []
    for outcome in OUTCOMES:
        true_positive = confusion[outcome][outcome]
        false_positive = sum(
            confusion[gold][outcome] for gold in OUTCOMES if gold != outcome
        )
        false_negative = sum(
            count for predicted, count in confusion[outcome].items() if predicted != outcome
        )
        support = sum(confusion[outcome].values())
        predicted_count = true_positive + false_positive
        precision = (
            true_positive / predicted_count if predicted_count else (0.0 if support else None)
        )
        recall = true_positive / support if support else None
        f1 = None
        if precision is not None and recall is not None:
            f1 = 0.0 if precision + recall == 0 else 2 * precision * recall / (precision + recall)
        class_metrics[outcome] = {
            "f1": _rounded(f1),
            "precision": _rounded(precision),
            "predicted": predicted_count,
            "recall": _rounded(recall),
            "support": support,
        }
        if precision is not None:
            macro_precision_values.append(precision)
        if recall is not None:
            macro_recall_values.append(recall)
        if f1 is not None:
            macro_f1_values.append(f1)
    matrix = {
        gold: {
            predicted: confusion[gold][predicted]
            for predicted in (*OUTCOMES, "__missing__")
        }
        for gold in OUTCOMES
    }
    def grouped(values: Mapping[str, list[int]]) -> dict[str, dict[str, object]]:
        return {
            key: {
                "accuracy": _rounded(counts[0] / counts[1]) if counts[1] else None,
                "correct": counts[0],
                "total": counts[1],
            }
            for key, counts in values.items()
        }
    return {
        "case_count": len(cases),
        "prediction_case_count": len(predictions),
        "missing_prediction_cases": missing_cases,
        "criterion_accuracy": _rounded(correct / expected_labels) if expected_labels else None,
        "correct_criterion_labels": correct,
        "expected_criterion_labels": expected_labels,
        "predicted_criterion_labels": present,
        "missing_criterion_predictions": missing_labels,
        "coverage": _rounded(present / expected_labels) if expected_labels else None,
        "per_criterion_accuracy": grouped(per_criterion_counts),
        "per_language_accuracy": grouped(per_language_counts),
        "confusion_matrix": matrix,
        "class_metrics": class_metrics,
        "macro_precision": _rounded(
            sum(macro_precision_values) / len(macro_precision_values)
        ) if macro_precision_values else None,
        "macro_recall": _rounded(
            sum(macro_recall_values) / len(macro_recall_values)
        ) if macro_recall_values else None,
        "macro_f1": _rounded(sum(macro_f1_values) / len(macro_f1_values))
        if macro_f1_values else None,
        "overall_score_mae": _rounded(sum(score_errors) / len(score_errors))
        if score_errors else None,
        "comparable_score_cases": len(score_errors),
        "missing_score_predictions": missing_scores,
        "review_needed_accuracy": _rounded(review_correct / len(cases))
        if cases else None,
    }
