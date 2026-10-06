from functools import lru_cache
from urllib.parse import urlsplit

from pydantic import field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Runtime configuration sourced from environment variables."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    app_env: str = "development"
    cors_origins: str = "http://localhost:3000"
    supabase_url: str | None = None
    supabase_publishable_key: str | None = None

    @field_validator("supabase_url")
    @classmethod
    def validate_supabase_url(cls, value: str | None) -> str | None:
        if value is None or not value.strip():
            return None

        normalized = value.strip().rstrip("/")
        parsed = urlsplit(normalized)
        is_local_http = parsed.scheme == "http" and parsed.hostname in {
            "localhost",
            "127.0.0.1",
        }
        if (
            (parsed.scheme != "https" and not is_local_http)
            or not parsed.netloc
            or parsed.username is not None
            or parsed.password is not None
            or parsed.path not in {"", "/"}
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError(
                "SUPABASE_URL must be an HTTPS origin, or a local HTTP origin"
            )
        return normalized

    @field_validator("supabase_publishable_key")
    @classmethod
    def normalize_publishable_key(cls, value: str | None) -> str | None:
        if value is None or not value.strip():
            return None
        return value.strip()

    @model_validator(mode="after")
    def reject_wildcard_cors(self) -> "Settings":
        if "*" in self.allowed_origins:
            raise ValueError(
                "CORS_ORIGINS must list explicit origins when credentials are enabled"
            )
        return self

    @property
    def allowed_origins(self) -> list[str]:
        return [
            origin.strip() for origin in self.cors_origins.split(",") if origin.strip()
        ]

    @property
    def supabase_issuer(self) -> str:
        if self.supabase_url is None:
            raise RuntimeError("SUPABASE_URL is required for protected API routes")
        return f"{self.supabase_url}/auth/v1"

    @property
    def supabase_jwks_url(self) -> str:
        return f"{self.supabase_issuer}/.well-known/jwks.json"

    @property
    def supabase_rest_url(self) -> str:
        if self.supabase_url is None:
            raise RuntimeError("SUPABASE_URL is required for protected API routes")
        return f"{self.supabase_url}/rest/v1"

    def require_publishable_key(self) -> str:
        if self.supabase_publishable_key is None:
            raise RuntimeError(
                "SUPABASE_PUBLISHABLE_KEY is required for workspace routes"
            )
        return self.supabase_publishable_key


@lru_cache
def get_settings() -> Settings:
    return Settings()
