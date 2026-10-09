import pytest

from callscope_worker.analysis import AnalysisResult, AnalysisValidationError


def valid_result(**overrides: object) -> dict[str, object]:
    value: dict[str, object] = {
        "summary": "Customer asked about pricing and requested a follow-up.",
        "sentiment": "neutral",
        "primary_intent": "pricing inquiry",
        "objections": ["Price is higher than expected"],
        "action_items": ["Send pricing details"],
        "topics": ["pricing", "follow-up"],
        "overall_score": 72,
    }
    value.update(overrides)
    return value


def test_analysis_result_accepts_exact_bounded_schema() -> None:
    result = AnalysisResult.from_mapping(valid_result())

    assert result.summary == "Customer asked about pricing and requested a follow-up."
    assert result.sentiment == "neutral"
    assert result.primary_intent == "pricing inquiry"
    assert result.objections == ["Price is higher than expected"]
    assert result.action_items == ["Send pricing details"]
    assert result.topics == ["pricing", "follow-up"]
    assert result.overall_score == 72


@pytest.mark.parametrize(
    "payload",
    [
        valid_result(extra="must be rejected"),
        valid_result(summary=""),
        valid_result(summary="x" * 10001),
        valid_result(sentiment="happy"),
        valid_result(primary_intent=""),
        valid_result(primary_intent="x" * 501),
        valid_result(objections=["x"] * 26),
        valid_result(objections=["x" * 1001]),
        valid_result(action_items=["x"] * 51),
        valid_result(action_items=["x" * 1001]),
        valid_result(topics=["x"] * 51),
        valid_result(topics=["x" * 201]),
        valid_result(overall_score=-1),
        valid_result(overall_score=101),
        valid_result(overall_score=True),
    ],
)
def test_analysis_result_rejects_invalid_or_extra_fields(
    payload: dict[str, object],
) -> None:
    with pytest.raises(AnalysisValidationError):
        AnalysisResult.from_mapping(payload)


def test_analysis_result_rejects_reasoning_or_model_wrapper_fields() -> None:
    for forbidden in ("thinking", "reasoning", "raw_response", "chain_of_thought"):
        with pytest.raises(AnalysisValidationError):
            AnalysisResult.from_mapping(valid_result(**{forbidden: "private reasoning"}))

import json

from callscope_worker.analysis import (
    OLLAMA_FORMAT_SCHEMA,
    parse_analysis_content,
)


def test_ollama_schema_is_closed_and_matches_analysis_contract() -> None:
    assert OLLAMA_FORMAT_SCHEMA["type"] == "object"
    assert OLLAMA_FORMAT_SCHEMA["additionalProperties"] is False

    properties = OLLAMA_FORMAT_SCHEMA["properties"]

    assert set(properties) == {
        "summary",
        "sentiment",
        "primary_intent",
        "objections",
        "action_items",
        "topics",
        "overall_score",
    }

    assert set(OLLAMA_FORMAT_SCHEMA["required"]) == set(properties)


def test_parse_analysis_content_accepts_only_exact_json_object() -> None:
    raw = json.dumps(valid_result())

    result = parse_analysis_content(raw)

    assert result.summary.startswith("Customer asked")
    assert result.overall_score == 72


@pytest.mark.parametrize(
    "raw",
    [
        "",
        "not json",
        '{"summary":"hello"} trailing text',
        '```json\n{"summary":"hello"}\n```',
        '{"thinking":"private reasoning"}',
        '["not", "an", "object"]',
        "null",
    ],
)
def test_parse_analysis_content_rejects_non_exact_model_output(raw: str) -> None:
    with pytest.raises(AnalysisValidationError):
        parse_analysis_content(raw)


def test_parse_analysis_content_never_includes_raw_output_in_error() -> None:
    secret_marker = "DO_NOT_LEAK_THIS_MODEL_OUTPUT"

    with pytest.raises(AnalysisValidationError) as error:
        parse_analysis_content(secret_marker)

    assert secret_marker not in str(error.value)