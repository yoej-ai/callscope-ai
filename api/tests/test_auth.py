import asyncio
import logging
from datetime import UTC, datetime, timedelta

import httpx2 as httpx
import jwt
import pytest

from app.auth import InvalidAccessToken, JwksCache
from tests.support import (
    TEST_PUBLISHABLE_KEY,
    TEST_SUPABASE_URL,
    TEST_USER_ID,
    SigningKey,
    assert_secret_not_exposed,
    bearer,
    build_test_client,
)


def test_health_remains_public() -> None:
    client = build_test_client(SigningKey())

    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_me_without_authorization_is_unauthorized() -> None:
    response = build_test_client(SigningKey()).get("/v1/me")

    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"


def test_me_rejects_malformed_authorization_headers() -> None:
    client = build_test_client(SigningKey())

    for authorization in ["Basic abc", "Bearer", "Bearer ", "Bearer one two"]:
        response = client.get(
            "/v1/me",
            headers={"Authorization": authorization},
        )
        assert response.status_code == 401
        assert response.headers["www-authenticate"] == "Bearer"


def test_me_rejects_malformed_jwt() -> None:
    response = build_test_client(SigningKey()).get(
        "/v1/me",
        headers=bearer("not-a-jwt"),
    )

    assert response.status_code == 401
    assert_secret_not_exposed(response.text, "not-a-jwt")


def test_me_rejects_expired_jwt() -> None:
    key = SigningKey()
    token = key.token(expires_at=datetime.now(UTC) - timedelta(seconds=1))

    response = build_test_client(key).get("/v1/me", headers=bearer(token))

    assert response.status_code == 401
    assert_secret_not_exposed(response.text, token)


def test_me_rejects_wrong_issuer() -> None:
    key = SigningKey()
    token = key.token(issuer="https://another-project.supabase.co/auth/v1")

    response = build_test_client(key).get("/v1/me", headers=bearer(token))

    assert response.status_code == 401


def test_me_rejects_untrusted_signature() -> None:
    trusted_key = SigningKey()
    untrusted_key = SigningKey(kid=trusted_key.kid)
    token = untrusted_key.token()

    response = build_test_client(trusted_key).get(
        "/v1/me",
        headers=bearer(token),
    )

    assert response.status_code == 401


def test_me_rejects_publishable_key_as_bearer_identity() -> None:
    response = build_test_client(SigningKey()).get(
        "/v1/me",
        headers=bearer(TEST_PUBLISHABLE_KEY),
    )

    assert response.status_code == 401


def test_me_rejects_unsigned_jwt() -> None:
    key = SigningKey()
    now = datetime.now(UTC)
    token = jwt.encode(
        {
            "aud": "authenticated",
            "exp": now + timedelta(minutes=5),
            "iss": f"{TEST_SUPABASE_URL}/auth/v1",
            "role": "authenticated",
            "sub": str(TEST_USER_ID),
        },
        key="",
        algorithm="none",
        headers={"kid": key.kid},
    )

    response = build_test_client(key).get("/v1/me", headers=bearer(token))

    assert response.status_code == 401


def test_me_rejects_non_uuid_subject() -> None:
    key = SigningKey()
    response = build_test_client(key).get(
        "/v1/me",
        headers=bearer(key.token(user_id="not-a-uuid")),
    )

    assert response.status_code == 401


@pytest.mark.parametrize("algorithm", ["RS256", "ES256"])
def test_me_accepts_supported_asymmetric_token(algorithm: str) -> None:
    key = SigningKey(algorithm=algorithm)
    token = key.token()

    response = build_test_client(key).get("/v1/me", headers=bearer(token))

    assert response.status_code == 200
    assert response.json() == {
        "user_id": str(TEST_USER_ID),
        "role": "authenticated",
    }
    assert_secret_not_exposed(response.text, token)


def test_me_rejects_algorithm_and_key_type_mismatch() -> None:
    signing_key = SigningKey(algorithm="RS256")
    mismatched_key = SigningKey(algorithm="ES256", kid=signing_key.kid)
    mismatched_jwk = {**mismatched_key.public_jwk, "alg": "RS256"}
    token = signing_key.token()

    def jwks_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"keys": [mismatched_jwk]})

    response = build_test_client(signing_key, jwks_handler=jwks_handler).get(
        "/v1/me",
        headers=bearer(token),
    )

    assert response.status_code == 401
    assert response.json() == {"detail": "Invalid or missing bearer token."}
    assert_secret_not_exposed(response.text, token)


def test_unknown_kid_forces_single_jwks_refresh() -> None:
    old_key = SigningKey(kid="old-key")
    rotated_key = SigningKey(kid="rotated-key")
    calls = 0

    def jwks_handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        keys = [old_key.public_jwk] if calls == 1 else [rotated_key.public_jwk]
        return httpx.Response(200, json={"keys": keys})

    client = build_test_client(old_key, jwks_handler=jwks_handler)
    response = client.get("/v1/me", headers=bearer(rotated_key.token()))

    assert response.status_code == 200
    assert calls == 2


def test_concurrent_unknown_kids_share_single_jwks_refresh() -> None:
    async def run_scenario() -> None:
        trusted_key = SigningKey(kid="trusted-key")
        calls = 0
        contender_count = 8
        contenders_ready = 0
        all_contenders_ready = asyncio.Event()
        start_contenders = asyncio.Event()
        refresh_started = asyncio.Event()
        release_refresh = asyncio.Event()

        async def jwks_handler(request: httpx.Request) -> httpx.Response:
            nonlocal calls
            calls += 1
            if calls == 2:
                refresh_started.set()
                await release_refresh.wait()
            return httpx.Response(200, json={"keys": [trusted_key.public_jwk]})

        cache = JwksCache(
            f"{TEST_SUPABASE_URL}/auth/v1/.well-known/jwks.json",
            transport=httpx.MockTransport(jwks_handler),
        )
        await cache.get_key(trusted_key.kid, trusted_key.algorithm)

        async def request_unknown_key(index: int) -> None:
            nonlocal contenders_ready
            contenders_ready += 1
            if contenders_ready == contender_count:
                all_contenders_ready.set()
            await start_contenders.wait()
            with pytest.raises(InvalidAccessToken, match="Unknown signing key"):
                await cache.get_key(f"unknown-key-{index}", "RS256")

        tasks = [
            asyncio.create_task(request_unknown_key(index))
            for index in range(contender_count)
        ]
        await all_contenders_ready.wait()
        start_contenders.set()
        await asyncio.wait_for(refresh_started.wait(), timeout=1.0)

        try:
            for _ in range(contender_count):
                await asyncio.sleep(0)
            assert calls == 2
        finally:
            release_refresh.set()

        await asyncio.gather(*tasks)
        assert calls == 2

    asyncio.run(run_scenario())


def test_repeated_unknown_kids_share_bounded_refresh_cooldown() -> None:
    trusted_key = SigningKey(kid="trusted-key")
    calls = 0

    def jwks_handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(200, json={"keys": [trusted_key.public_jwk]})

    client = build_test_client(trusted_key, jwks_handler=jwks_handler)

    assert client.get(
        "/v1/me",
        headers=bearer(trusted_key.token()),
    ).status_code == 200

    for index in range(4):
        unknown_key = SigningKey(kid=f"unknown-key-{index}")
        response = client.get(
            "/v1/me",
            headers=bearer(unknown_key.token()),
        )
        assert response.status_code == 401
        assert response.json() == {"detail": "Invalid or missing bearer token."}

    assert calls == 2


def test_key_rotation_recovers_after_unknown_kid_refresh_cooldown() -> None:
    old_key = SigningKey(kid="old-key")
    rotated_key = SigningKey(kid="rotated-key")
    current_time = 100.0
    calls = 0

    def clock() -> float:
        return current_time

    def jwks_handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        keys = [old_key.public_jwk] if calls <= 2 else [rotated_key.public_jwk]
        return httpx.Response(200, json={"keys": keys})

    client = build_test_client(
        old_key,
        jwks_handler=jwks_handler,
        jwks_clock=clock,
        unknown_kid_refresh_cooldown_seconds=10.0,
    )

    assert client.get(
        "/v1/me",
        headers=bearer(old_key.token()),
    ).status_code == 200

    first_attempt = client.get(
        "/v1/me",
        headers=bearer(rotated_key.token()),
    )
    repeated_attempt = client.get(
        "/v1/me",
        headers=bearer(rotated_key.token()),
    )

    assert first_attempt.status_code == 401
    assert repeated_attempt.status_code == 401
    assert calls == 2

    current_time += 11.0
    recovered = client.get(
        "/v1/me",
        headers=bearer(rotated_key.token()),
    )

    assert recovered.status_code == 200
    assert calls == 3


def test_jwks_outage_returns_safe_service_unavailable() -> None:
    key = SigningKey()

    def jwks_handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("offline", request=request)

    response = build_test_client(key, jwks_handler=jwks_handler).get(
        "/v1/me",
        headers=bearer(key.token()),
    )

    assert response.status_code == 503
    assert response.json() == {"detail": "Authentication service is unavailable."}


def test_rejected_token_is_not_logged(caplog: pytest.LogCaptureFixture) -> None:
    key = SigningKey()
    token = key.token(expires_at=datetime.now(UTC) - timedelta(seconds=1))
    caplog.set_level(logging.DEBUG)

    response = build_test_client(key).get("/v1/me", headers=bearer(token))

    assert response.status_code == 401
    assert_secret_not_exposed(caplog.text, token)


def test_me_rejects_wrong_audience_and_role() -> None:
    key = SigningKey()
    client = build_test_client(key)

    wrong_audience = client.get(
        "/v1/me",
        headers=bearer(key.token(audience="anon")),
    )
    wrong_role = client.get(
        "/v1/me",
        headers=bearer(key.token(role="anon")),
    )

    assert wrong_audience.status_code == 401
    assert wrong_role.status_code == 401
    assert TEST_SUPABASE_URL not in wrong_audience.text
