import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app


def test_health_returns_ok_without_supabase_config(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("SUPABASE_URL", raising=False)
    monkeypatch.delenv("SUPABASE_PUBLISHABLE_KEY", raising=False)
    settings = Settings(_env_file=None)

    response = TestClient(create_app(settings=settings)).get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
