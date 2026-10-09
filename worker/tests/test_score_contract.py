from __future__ import annotations

import json

import httpx

from callscope_worker.ollama import (
    OllamaAnalyzer,
    OllamaSettings,
)


MODEL = "qwen3:4b-instruct"


def settings() -> OllamaSettings:
    return OllamaSettings(
        base_url="http://127.0.0.1:11434",
        model=MODEL,
    )


def analyze_content(content: dict[str, object]):
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/chat"

        return httpx.Response(
            200,
            json={
                "model": MODEL,
                "message": {
                    "role": "assistant",
                    "content": json.dumps(content),
                },
                "done": True,
            },
        )

    with httpx.Client(
        base_url="http://127.0.0.1:11434/",
        transport=httpx.MockTransport(handler),
        trust_env=False,
        follow_redirects=False,
    ) as http:
        analyzer = OllamaAnalyzer(
            settings(),
            http=http,
        )

        return analyzer.analyze(
            "Synthetic unit-test transcript",
            language="en",
        )


def test_no_business_content_normalizes_score_to_null() -> None:
    result = analyze_content(
        {
            "summary": (
                "No genuine business or conversational content is present."
            ),
            "sentiment": "neutral",
            "primary_intent": "none",
            "objections": [],
            "action_items": [],
            "topics": [],
            "overall_score": 0,
        }
    )

    assert result.primary_intent == "none"
    assert result.overall_score is None


def test_genuine_business_rejection_keeps_low_score() -> None:
    result = analyze_content(
        {
            "summary": (
                "Customer declined the offer and does not want to proceed."
            ),
            "sentiment": "negative",
            "primary_intent": "not interested",
            "objections": [
                "Customer does not want the service",
            ],
            "action_items": [],
            "topics": [
                "service decision",
            ],
            "overall_score": 10,
        }
    )

    assert result.primary_intent == "not interested"
    assert result.overall_score == 10