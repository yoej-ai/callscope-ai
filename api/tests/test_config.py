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


def test_supabase_url_is_normalized() -> None:
    settings = Settings(
        supabase_url="https://project-ref.supabase.co/",
        _env_file=None,
    )

    assert settings.supabase_url == "https://project-ref.supabase.co"
    assert settings.supabase_issuer == "https://project-ref.supabase.co/auth/v1"


@pytest.mark.parametrize(
    "value",
    [
        "http://project-ref.supabase.co",
        "https://user:password@project-ref.supabase.co",
        "https://project-ref.supabase.co/path",
        "https://project-ref.supabase.co?query=value",
    ],
)
def test_invalid_supabase_url_is_rejected(value: str) -> None:
    with pytest.raises(ValidationError):
        Settings(supabase_url=value, _env_file=None)
