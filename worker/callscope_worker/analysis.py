"""Strict, bounded validation for AI call-analysis results.

Model output is untrusted. Only validated structured fields may leave this
module. Raw model responses and reasoning must never be persisted.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Mapping


EXPECTED_FIELDS = frozenset(
    {
        "summary",
        "sentiment",
        "primary_intent",
        "objections",
        "action_items",
        "topics",
        "overall_score",
    }
)

VALID_SENTIMENTS = frozenset(
    {
        "positive",
        "neutral",
        "negative",
        "mixed",
    }
)


class AnalysisValidationError(ValueError):
    """Safe validation failure that never contains raw model output."""


def _bounded_string(
    value: object,
    *,
    field: str,
    maximum_characters: int,
) -> str:
    if not isinstance(value, str):
        raise AnalysisValidationError(f"{field}_invalid")

    normalized = value.strip()

    if not 1 <= len(normalized) <= maximum_characters:
        raise AnalysisValidationError(f"{field}_invalid")

    return normalized


def _bounded_string_array(
    value: object,
    *,
    field: str,
    maximum_elements: int,
    maximum_serialized_bytes: int,
    maximum_item_characters: int,
) -> list[str]:
    if not isinstance(value, list):
        raise AnalysisValidationError(f"{field}_invalid")

    if len(value) > maximum_elements:
        raise AnalysisValidationError(f"{field}_invalid")

    normalized: list[str] = []

    for item in value:
        normalized.append(
            _bounded_string(
                item,
                field=field,
                maximum_characters=maximum_item_characters,
            )
        )

    serialized = json.dumps(
        normalized,
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")

    if len(serialized) > maximum_serialized_bytes:
        raise AnalysisValidationError(f"{field}_invalid")

    return normalized


@dataclass(frozen=True)
class AnalysisResult:
    summary: str
    sentiment: str
    primary_intent: str
    objections: list[str]
    action_items: list[str]
    topics: list[str]
    overall_score: int | None

    @classmethod
    def from_mapping(cls, payload: object) -> "AnalysisResult":
        if not isinstance(payload, Mapping):
            raise AnalysisValidationError("analysis_result_invalid")

        if set(payload.keys()) != EXPECTED_FIELDS:
            raise AnalysisValidationError("analysis_fields_invalid")

        summary = _bounded_string(
            payload["summary"],
            field="summary",
            maximum_characters=10_000,
        )

        sentiment_value = payload["sentiment"]

        if not isinstance(sentiment_value, str):
            raise AnalysisValidationError("sentiment_invalid")

        sentiment = sentiment_value.strip().lower()

        if sentiment not in VALID_SENTIMENTS:
            raise AnalysisValidationError("sentiment_invalid")

        primary_intent = _bounded_string(
            payload["primary_intent"],
            field="primary_intent",
            maximum_characters=500,
        )

        objections = _bounded_string_array(
            payload["objections"],
            field="objections",
            maximum_elements=25,
            maximum_serialized_bytes=8192,
            maximum_item_characters=1000,
        )

        action_items = _bounded_string_array(
            payload["action_items"],
            field="action_items",
            maximum_elements=50,
            maximum_serialized_bytes=32768,
            maximum_item_characters=1000,
        )

        topics = _bounded_string_array(
            payload["topics"],
            field="topics",
            maximum_elements=50,
            maximum_serialized_bytes=8192,
            maximum_item_characters=200,
        )

        score = payload["overall_score"]

        if score is not None:
            if type(score) is not int or not 0 <= score <= 100:
                raise AnalysisValidationError("overall_score_invalid")

        return cls(
            summary=summary,
            sentiment=sentiment,
            primary_intent=primary_intent,
            objections=objections,
            action_items=action_items,
            topics=topics,
            overall_score=score,
        )


OLLAMA_FORMAT_SCHEMA: dict[str, object] = {
    "type": "object",
    "properties": {
        "summary": {
            "type": "string",
            "minLength": 1,
            "maxLength": 10000,
        },
        "sentiment": {
            "type": "string",
            "enum": [
                "positive",
                "neutral",
                "negative",
                "mixed",
            ],
        },
        "primary_intent": {
            "type": "string",
            "minLength": 1,
            "maxLength": 500,
        },
        "objections": {
            "type": "array",
            "maxItems": 25,
            "items": {
                "type": "string",
                "minLength": 1,
                "maxLength": 1000,
            },
        },
        "action_items": {
            "type": "array",
            "maxItems": 50,
            "items": {
                "type": "string",
                "minLength": 1,
                "maxLength": 1000,
            },
        },
        "topics": {
            "type": "array",
            "maxItems": 50,
            "items": {
                "type": "string",
                "minLength": 1,
                "maxLength": 200,
            },
        },
        "overall_score": {
            "type": [
                "integer",
                "null",
            ],
            "minimum": 0,
            "maximum": 100,
        },
    },
    "required": [
        "summary",
        "sentiment",
        "primary_intent",
        "objections",
        "action_items",
        "topics",
        "overall_score",
    ],
    "additionalProperties": False,
}


def parse_analysis_content(raw: object) -> AnalysisResult:
    """Parse untrusted model content without leaking it through errors."""

    if not isinstance(raw, str) or not raw:
        raise AnalysisValidationError("analysis_json_invalid")

    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise AnalysisValidationError("analysis_json_invalid") from exc

    if not isinstance(payload, dict):
        raise AnalysisValidationError("analysis_json_invalid")

    return AnalysisResult.from_mapping(payload)