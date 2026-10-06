import pytest
from pydantic import ValidationError

from app.config import Settings


def test_cors_origins_are_parsed_from_csv() -> None:
    settings = Settings(
        cors_origins="http://localhost:3000, https://app.example.com",
        _env_file=None,
    )

    assert settings.allowed_origins == [
        "http://localhost:3000",
        "https://app.example.com",
    ]


def test_wildcard_cors_is_rejected() -> None:
    with pytest.raises(ValidationError):
        Settings(cors_origins="*", _env_file=None)
