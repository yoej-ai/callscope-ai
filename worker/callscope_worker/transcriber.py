"""Local speech-to-text with strict media duration checks.

Media stays in an isolated local temporary directory. A local faster-whisper
model is used; only the resulting transcript is returned to Supabase.
"""
from __future__ import annotations

import json
import math
import shutil
import subprocess
from numbers import Real
from pathlib import Path

from .core import LANGUAGE_RE, Transcript, WorkerError

MAX_DURATION_SECONDS = 3600
MAX_SEGMENTS = 10000
MIN_LANGUAGE_PROBABILITY = 0.8


class TranscriptionStartupError(RuntimeError):
    """Safe local dependency/model startup failure code."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def reliable_language_code(
    language: object,
    probability: object,
) -> str | None:
    """Return only well-formed, high-confidence model language metadata."""

    if not isinstance(language, str):
        return None

    normalized_language = language.strip().lower()
    if not normalized_language or not LANGUAGE_RE.fullmatch(normalized_language):
        return None

    if isinstance(probability, bool) or not isinstance(probability, Real):
        return None

    normalized_probability = float(probability)
    if (
        not math.isfinite(normalized_probability)
        or not 0 <= normalized_probability <= 1
        or normalized_probability < MIN_LANGUAGE_PROBABILITY
    ):
        return None

    return normalized_language


def probe_audio(path: Path) -> int:
    """Reject unsupported/corrupt/mislabelled or oversized-duration media."""
    if not shutil.which("ffprobe"):
        raise RuntimeError("ffprobe (FFmpeg) must be installed before worker startup")
    try:
        completed = subprocess.run(
            [
                "ffprobe", "-v", "error",
                "-show_entries", "format=duration:stream=codec_type",
                "-of", "json", str(path),
            ],
            capture_output=True,
            text=True,
            timeout=20,
            check=True,
        )
        payload = json.loads(completed.stdout)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError) as exc:
        raise WorkerError("audio_probe_failed", retryable=False) from exc
    if not isinstance(payload, dict):
        raise WorkerError("audio_probe_failed", retryable=False)
    streams = payload.get("streams")
    if (
        not isinstance(streams, list)
        or not streams
        or sum(s.get("codec_type") == "audio" for s in streams if isinstance(s, dict)) != 1
        or any(not isinstance(s, dict) or s.get("codec_type") != "audio" for s in streams)
    ):
        raise WorkerError("audio_stream_invalid", retryable=False)
    try:
        seconds = float(payload["format"]["duration"])
    except (KeyError, TypeError, ValueError, OverflowError) as exc:
        raise WorkerError("audio_duration_invalid", retryable=False) from exc
    if not math.isfinite(seconds) or seconds <= 0 or seconds > MAX_DURATION_SECONDS:
        raise WorkerError("audio_duration_invalid", retryable=False)
    return int(math.ceil(seconds))


class FasterWhisperTranscriber:
    """Loads an open-source CPU model once, before claiming any jobs."""

    def __init__(self, model_name: str) -> None:
        if not shutil.which("ffprobe"):
            raise TranscriptionStartupError("ffprobe_unavailable")
        try:
            from faster_whisper import WhisperModel  # noqa: PLC0415
        except ImportError as exc:
            raise TranscriptionStartupError("speech_dependencies_unavailable") from exc
        # First execution may download model weights. Never download private audio.
        try:
            self.model = WhisperModel(model_name, device="cpu", compute_type="int8")
        except Exception as exc:
            raise TranscriptionStartupError("transcription_model_unavailable") from exc

    def transcribe(self, path: Path) -> Transcript:
        verified_duration = probe_audio(path)
        try:
            iterator, info = self.model.transcribe(
                str(path), beam_size=1, vad_filter=True
            )
            items: list[dict[str, object]] = []
            snippets: list[str] = []
            for segment in iterator:
                snippet = str(segment.text).strip()
                if not snippet:
                    continue
                start, end = float(segment.start), float(segment.end)
                if (
                    not math.isfinite(start)
                    or not math.isfinite(end)
                    or start < 0
                    or end < start
                    or end > MAX_DURATION_SECONDS + 1
                ):
                    raise WorkerError("invalid_segment_timing", retryable=False)
                if len(items) >= MAX_SEGMENTS:
                    raise WorkerError("too_many_segments", retryable=False)
                items.append({
                    "start": round(start, 3),
                    "end": round(end, 3),
                    "text": snippet,
                })
                snippets.append(snippet)
                if sum(map(len, snippets)) > 1_000_000:
                    raise WorkerError("transcript_too_large", retryable=False)
            language = reliable_language_code(
                getattr(info, "language", None),
                getattr(info, "language_probability", None),
            )
        except WorkerError:
            raise
        except Exception as exc:
            raise WorkerError("transcription_engine_failed", retryable=True) from exc
        return Transcript(
            text=" ".join(snippets),
            language=language,
            segments=items,
            duration_seconds=verified_duration,
        )
