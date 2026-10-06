from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from hmac import compare_digest
from typing import Any
from uuid import UUID

import httpx2 as httpx
import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

from app.auth import JwksCache, SupabaseJwtVerifier
from app.config import Settings
from app.main import create_app
from app.supabase_data import SupabaseWorkspaceClient

TEST_SUPABASE_URL = "https://test-project.supabase.co"
TEST_PUBLISHABLE_KEY = "test-publishable-key"
TEST_KEY_ID = "test-signing-key"
TEST_USER_ID = UUID("4dd668d0-d998-4d97-a5c1-cd3089ff30f7")


class SigningKey:
    def __init__(self, *, kid: str = TEST_KEY_ID) -> None:
        self.kid = kid
        self.private_key = rsa.generate_private_key(
            public_exponent=65537,
            key_size=2048,
        )
        public_jwk = jwt.algorithms.RSAAlgorithm.to_jwk(
            self.private_key.public_key(),
            as_dict=True,
        )
        public_jwk.update({"alg": "RS256", "kid": kid, "use": "sig"})
        self.public_jwk = public_jwk

    def token(
        self,
        *,
        user_id: UUID | str = TEST_USER_ID,
        issuer: str = f"{TEST_SUPABASE_URL}/auth/v1",
        audience: str = "authenticated",
        role: str = "authenticated",
        expires_at: datetime | None = None,
    ) -> str:
        now = datetime.now(UTC)
        claims = {
            "aud": audience,
            "exp": expires_at or now + timedelta(minutes=5),
            "iat": now,
            "iss": issuer,
            "role": role,
            "sub": str(user_id),
        }
        return jwt.encode(
            claims,
            self.private_key,
            algorithm="RS256",
            headers={"kid": self.kid},
        )


def build_test_client(
    signing_key: SigningKey,
    *,
    jwks_handler: Callable[[httpx.Request], httpx.Response] | None = None,
    workspace_handler: Callable[[httpx.Request], httpx.Response] | None = None,
) -> TestClient:
    settings = Settings(
        supabase_url=TEST_SUPABASE_URL,
        supabase_publishable_key=TEST_PUBLISHABLE_KEY,
        _env_file=None,
    )

    def default_jwks_handler(request: httpx.Request) -> httpx.Response:
        assert request.url == f"{TEST_SUPABASE_URL}/auth/v1/.well-known/jwks.json"
        return httpx.Response(200, json={"keys": [signing_key.public_jwk]})

    def default_workspace_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=[])

    jwks_cache = JwksCache(
        settings.supabase_jwks_url,
        transport=httpx.MockTransport(jwks_handler or default_jwks_handler),
    )
    verifier = SupabaseJwtVerifier(settings, jwks_cache=jwks_cache)
    workspace_client = SupabaseWorkspaceClient(
        settings,
        transport=httpx.MockTransport(workspace_handler or default_workspace_handler),
    )
    return TestClient(
        create_app(
            settings=settings,
            jwt_verifier=verifier,
            workspace_client=workspace_client,
        )
    )


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def safe_response_snapshot(response: Any) -> tuple[int, dict[str, Any]]:
    return response.status_code, response.json()


def assert_secret_equal(actual: str, expected: str) -> None:
    if not compare_digest(actual, expected):
        raise AssertionError("Credential forwarding did not match the expected value")


def assert_secret_not_exposed(content: str, secret: str) -> None:
    if secret in content:
        raise AssertionError("A credential was exposed in an API response")
