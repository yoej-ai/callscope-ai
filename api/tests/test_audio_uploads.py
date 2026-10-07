import json
from uuid import UUID

import httpx2 as httpx
import pytest

from app.audio_uploads import MAX_AUDIO_SIZE_BYTES
from tests.support import (
    TEST_PUBLISHABLE_KEY,
    SigningKey,
    assert_secret_equal,
    assert_secret_not_exposed,
    bearer,
    build_test_client,
    safe_response_snapshot,
)

WORKSPACE_ID = UUID("76a13040-1d54-4abc-a286-615cc06d781a")
OTHER_WORKSPACE_ID = UUID("3fbd71e6-bd27-494a-a70f-8cc780d703de")
CALL_ID = UUID("6e82a7b5-a82a-4b95-9fd0-cfc7619c85a8")
STORAGE_PATH = f"{WORKSPACE_ID}/{CALL_ID}/source.mp3"
INITIATE_PATH = f"/v1/workspaces/{WORKSPACE_ID}/calls/uploads"
COMPLETE_PATH = f"/v1/workspaces/{WORKSPACE_ID}/calls/{CALL_ID}/complete"
RECONCILE_PATH = f"/v1/workspaces/{WORKSPACE_ID}/calls/uploads/reconcile"
VALID_REQUEST = {
    "filename": "customer-call.mp3",
    "content_type": "audio/mpeg",
    "size_bytes": 1_048_576,
}
PENDING_RESPONSE = {
    "call_id": str(CALL_ID),
    "workspace_id": str(WORKSPACE_ID),
    "storage_bucket": "call-audio",
    "storage_path": STORAGE_PATH,
    "content_type": "audio/mpeg",
    "size_bytes": 1_048_576,
}


def test_initiate_upload_requires_authentication() -> None:
    response = build_test_client(SigningKey()).post(
        INITIATE_PATH,
        json=VALID_REQUEST,
    )

    assert response.status_code == 401


def test_initiate_upload_uses_user_bearer_and_returns_minimum_grant() -> None:
    key = SigningKey()
    token = key.token()
    observed_requests: list[httpx.Request] = []
    signed_token = "signed-upload-token"

    def upload_handler(request: httpx.Request) -> httpx.Response:
        observed_requests.append(request)
        if request.url.path.endswith("/rpc/create_call_upload"):
            return httpx.Response(200, json=[PENDING_RESPONSE])
        if "/object/upload/sign/" in request.url.path:
            return httpx.Response(
                200,
                json={
                    "url": (
                        "/object/upload/sign/call-audio/"
                        f"{STORAGE_PATH}?token={signed_token}"
                    )
                },
            )
        raise AssertionError(f"Unexpected request path: {request.url.path}")

    response = build_test_client(key, upload_handler=upload_handler).post(
        INITIATE_PATH,
        headers=bearer(token),
        json=VALID_REQUEST,
    )

    assert response.status_code == 201
    assert response.json() == {
        "call_id": str(CALL_ID),
        "bucket": "call-audio",
        "path": STORAGE_PATH,
        "upload_token": signed_token,
        "expires_in_seconds": 7200,
    }
    assert len(observed_requests) == 2
    create_request, signing_request = observed_requests
    for request in observed_requests:
        assert request.headers["apikey"] == TEST_PUBLISHABLE_KEY
        assert_secret_equal(request.headers["authorization"], f"Bearer {token}")
        assert request.headers["accept"] == "application/json"

    assert json.loads(create_request.content) == {
        "p_workspace_id": str(WORKSPACE_ID),
        "p_original_filename": "customer-call.mp3",
        "p_content_type": "audio/mpeg",
        "p_size_bytes": 1_048_576,
    }
    assert signing_request.url.path.endswith(
        f"/object/upload/sign/call-audio/{STORAGE_PATH}"
    )
    assert json.loads(signing_request.content) == {}
    assert "x-upsert" not in signing_request.headers
    assert_secret_not_exposed(response.text, token)


@pytest.mark.parametrize("size_bytes", [0, MAX_AUDIO_SIZE_BYTES + 1])
def test_initiate_upload_rejects_invalid_size(size_bytes: int) -> None:
    key = SigningKey()
    response = build_test_client(key).post(
        INITIATE_PATH,
        headers=bearer(key.token()),
        json={**VALID_REQUEST, "size_bytes": size_bytes},
    )

    assert response.status_code == 422


def test_initiate_upload_rejects_unsupported_extension() -> None:
    key = SigningKey()
    response = build_test_client(key).post(
        INITIATE_PATH,
        headers=bearer(key.token()),
        json={**VALID_REQUEST, "filename": "customer-call.exe"},
    )

    assert response.status_code == 422


def test_initiate_upload_rejects_unsupported_mime() -> None:
    key = SigningKey()
    response = build_test_client(key).post(
        INITIATE_PATH,
        headers=bearer(key.token()),
        json={**VALID_REQUEST, "content_type": "application/octet-stream"},
    )

    assert response.status_code == 422


def test_initiate_upload_rejects_extension_mime_mismatch() -> None:
    key = SigningKey()
    response = build_test_client(key).post(
        INITIATE_PATH,
        headers=bearer(key.token()),
        json={**VALID_REQUEST, "content_type": "audio/wav"},
    )

    assert response.status_code == 422


def test_initiate_upload_hides_inaccessible_workspace() -> None:
    key = SigningKey()

    def upload_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=[])

    response = build_test_client(key, upload_handler=upload_handler).post(
        INITIATE_PATH,
        headers=bearer(key.token()),
        json=VALID_REQUEST,
    )

    assert response.status_code == 404
    assert response.json() == {"detail": "Workspace not found."}


def test_initiate_upload_maps_supabase_auth_rejection_safely() -> None:
    key = SigningKey()
    token = key.token()

    def upload_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(401, json={"message": "private auth detail"})

    response = build_test_client(key, upload_handler=upload_handler).post(
        INITIATE_PATH,
        headers=bearer(token),
        json=VALID_REQUEST,
    )

    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"
    assert response.json() == {"detail": "The user session was rejected."}
    assert "private auth detail" not in response.text
    assert_secret_not_exposed(response.text, token)


def test_initiate_upload_maps_rest_failure_safely() -> None:
    key = SigningKey()
    token = key.token()

    def upload_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, json={"message": "private database detail"})

    response = build_test_client(key, upload_handler=upload_handler).post(
        INITIATE_PATH,
        headers=bearer(token),
        json=VALID_REQUEST,
    )

    assert response.status_code == 503
    assert response.json() == {"detail": "Upload service is unavailable."}
    assert "private database detail" not in response.text
    assert_secret_not_exposed(response.text, token)


def test_storage_signing_failure_aborts_pending_row_without_leaking_secrets(
    caplog: pytest.LogCaptureFixture,
) -> None:
    key = SigningKey()
    token = key.token()
    upstream_signed_token = "upstream-signed-secret"
    observed_paths: list[str] = []

    def upload_handler(request: httpx.Request) -> httpx.Response:
        observed_paths.append(request.url.path)
        if request.url.path.endswith("/rpc/create_call_upload"):
            return httpx.Response(200, json=[PENDING_RESPONSE])
        if "/object/upload/sign/" in request.url.path:
            return httpx.Response(
                503,
                json={"message": upstream_signed_token},
            )
        if request.url.path.endswith("/rpc/abort_call_upload"):
            return httpx.Response(200, json=True)
        raise AssertionError(f"Unexpected request path: {request.url.path}")

    response = build_test_client(key, upload_handler=upload_handler).post(
        INITIATE_PATH,
        headers=bearer(token),
        json=VALID_REQUEST,
    )

    assert response.status_code == 503
    assert observed_paths[-1].endswith("/rpc/abort_call_upload")
    assert upstream_signed_token not in response.text
    assert upstream_signed_token not in caplog.text
    assert_secret_not_exposed(response.text, token)
    assert_secret_not_exposed(caplog.text, token)


def test_malformed_storage_signing_response_is_safe_and_aborted() -> None:
    key = SigningKey()
    token = key.token()
    observed_paths: list[str] = []

    def upload_handler(request: httpx.Request) -> httpx.Response:
        observed_paths.append(request.url.path)
        if request.url.path.endswith("/rpc/create_call_upload"):
            return httpx.Response(200, json=[PENDING_RESPONSE])
        if "/object/upload/sign/" in request.url.path:
            return httpx.Response(200, json={"url": "/unexpected?token=private"})
        if request.url.path.endswith("/rpc/abort_call_upload"):
            return httpx.Response(200, json=True)
        raise AssertionError(f"Unexpected request path: {request.url.path}")

    response = build_test_client(key, upload_handler=upload_handler).post(
        INITIATE_PATH,
        headers=bearer(token),
        json=VALID_REQUEST,
    )

    assert response.status_code == 503
    assert observed_paths[-1].endswith("/rpc/abort_call_upload")
    assert "private" not in response.text
    assert_secret_not_exposed(response.text, token)


def test_complete_upload_returns_uploaded_status() -> None:
    key = SigningKey()
    token = key.token()

    def upload_handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path.endswith("/rpc/finalize_call_upload")
        assert json.loads(request.content) == {
            "p_workspace_id": str(WORKSPACE_ID),
            "p_call_id": str(CALL_ID),
        }
        assert_secret_equal(request.headers["authorization"], f"Bearer {token}")
        return httpx.Response(
            200,
            json=[{"call_id": str(CALL_ID), "status": "uploaded"}],
        )

    response = build_test_client(key, upload_handler=upload_handler).post(
        COMPLETE_PATH,
        headers=bearer(token),
    )

    assert response.status_code == 200
    assert response.json() == {"call_id": str(CALL_ID), "status": "uploaded"}
    assert_secret_not_exposed(response.text, token)


def test_complete_before_object_exists_is_non_enumerating() -> None:
    key = SigningKey()

    def upload_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=[])

    response = build_test_client(key, upload_handler=upload_handler).post(
        COMPLETE_PATH,
        headers=bearer(key.token()),
    )

    assert response.status_code == 404
    assert response.json() == {"detail": "Call upload not found."}


def test_cross_tenant_and_missing_completion_are_indistinguishable() -> None:
    key = SigningKey()
    headers = bearer(key.token())

    def upload_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=[])

    client = build_test_client(key, upload_handler=upload_handler)
    missing = client.post(COMPLETE_PATH, headers=headers)
    cross_tenant = client.post(
        f"/v1/workspaces/{OTHER_WORKSPACE_ID}/calls/{CALL_ID}/complete",
        headers=headers,
    )

    assert safe_response_snapshot(missing) == safe_response_snapshot(cross_tenant)
    assert safe_response_snapshot(missing) == (
        404,
        {"detail": "Call upload not found."},
    )


def test_complete_maps_supabase_auth_rejection_safely() -> None:
    key = SigningKey()
    token = key.token()

    def upload_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(401, json={"message": "private auth detail"})

    response = build_test_client(key, upload_handler=upload_handler).post(
        COMPLETE_PATH,
        headers=bearer(token),
    )

    assert response.status_code == 401
    assert response.json() == {"detail": "The user session was rejected."}
    assert "private auth detail" not in response.text
    assert_secret_not_exposed(response.text, token)


def test_reconcile_uploads_requires_authentication() -> None:
    response = build_test_client(SigningKey()).post(RECONCILE_PATH)

    assert response.status_code == 401


def test_reconcile_uploads_parses_bounded_results_and_counts_outcomes() -> None:
    key = SigningKey()
    token = key.token()
    deleted_call = UUID("7e82a7b5-a82a-4b95-9fd0-cfc7619c85a8")
    failed_call = UUID("8e82a7b5-a82a-4b95-9fd0-cfc7619c85a8")

    def upload_handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET":
            assert dict(request.url.params.multi_items()) == {
                "id": f"eq.{WORKSPACE_ID}",
                "select": "id",
                "limit": "1",
            }
            return httpx.Response(200, json=[{"id": str(WORKSPACE_ID)}])
        assert request.url.path.endswith("/rpc/reconcile_stale_call_uploads")
        assert json.loads(request.content) == {
            "p_workspace_id": str(WORKSPACE_ID),
            "p_limit": 20,
        }
        assert_secret_equal(request.headers["authorization"], f"Bearer {token}")
        return httpx.Response(
            200,
            json=[
                {"call_id": str(CALL_ID), "outcome": "uploaded"},
                {"call_id": str(deleted_call), "outcome": "deleted"},
                {"call_id": str(failed_call), "outcome": "failed"},
            ],
        )

    response = build_test_client(key, upload_handler=upload_handler).post(
        RECONCILE_PATH,
        headers=bearer(token),
    )

    assert response.status_code == 200
    assert response.json() == {
        "processed": 3,
        "uploaded": 1,
        "deleted": 1,
        "failed": 1,
        "results": [
            {"call_id": str(CALL_ID), "outcome": "uploaded"},
            {"call_id": str(deleted_call), "outcome": "deleted"},
            {"call_id": str(failed_call), "outcome": "failed"},
        ],
    }
    assert_secret_not_exposed(response.text, token)


@pytest.mark.parametrize(
    "payload",
    [
        {"call_id": str(CALL_ID), "outcome": "uploaded"},
        [{"call_id": str(CALL_ID), "outcome": "invalid"}],
        [
            {"call_id": str(CALL_ID), "outcome": "uploaded"},
            {"call_id": str(CALL_ID), "outcome": "uploaded"},
        ],
    ],
)
def test_reconcile_uploads_rejects_malformed_upstream_response(payload: object) -> None:
    key = SigningKey()

    def upload_handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET":
            return httpx.Response(200, json=[{"id": str(WORKSPACE_ID)}])
        return httpx.Response(200, json=payload)

    response = build_test_client(key, upload_handler=upload_handler).post(
        RECONCILE_PATH,
        headers=bearer(key.token()),
    )

    assert response.status_code == 503
    assert response.json() == {"detail": "Upload service is unavailable."}


def test_reconcile_uploads_maps_upstream_failures_without_body_leakage() -> None:
    key = SigningKey()
    token = key.token()

    def upload_handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET":
            return httpx.Response(200, json=[{"id": str(WORKSPACE_ID)}])
        return httpx.Response(500, json={"message": "private reconciliation detail"})

    response = build_test_client(key, upload_handler=upload_handler).post(
        RECONCILE_PATH,
        headers=bearer(token),
    )

    assert response.status_code == 503
    assert "private reconciliation detail" not in response.text
    assert_secret_not_exposed(response.text, token)


def test_reconcile_hidden_workspace_is_generic_not_found() -> None:
    key = SigningKey()

    def upload_handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "GET"
        return httpx.Response(200, json=[])

    response = build_test_client(key, upload_handler=upload_handler).post(
        RECONCILE_PATH,
        headers=bearer(key.token()),
    )

    assert response.status_code == 404
    assert response.json() == {"detail": "Workspace not found."}


def test_reconcile_maps_supabase_auth_rejection_safely() -> None:
    key = SigningKey()
    token = key.token()

    def upload_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(401, json={"message": "private auth detail"})

    response = build_test_client(key, upload_handler=upload_handler).post(
        RECONCILE_PATH,
        headers=bearer(token),
    )

    assert response.status_code == 401
    assert response.json() == {"detail": "The user session was rejected."}
    assert "private auth detail" not in response.text
    assert_secret_not_exposed(response.text, token)
