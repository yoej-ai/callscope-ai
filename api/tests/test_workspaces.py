from uuid import UUID

import httpx2 as httpx

from tests.support import (
    TEST_PUBLISHABLE_KEY,
    TEST_USER_ID,
    SigningKey,
    assert_secret_equal,
    assert_secret_not_exposed,
    bearer,
    build_test_client,
    safe_response_snapshot,
)

WORKSPACE_ID = UUID("76a13040-1d54-4abc-a286-615cc06d781a")
OTHER_USER_ID = UUID("6c7a1596-4578-4b5b-a839-a69cb0e2775e")
CREATED_AT = "2026-10-06T10:00:00+00:00"


def test_workspace_requires_authentication() -> None:
    response = build_test_client(SigningKey()).get(f"/v1/workspaces/{WORKSPACE_ID}")

    assert response.status_code == 401


def test_workspace_rejects_malformed_uuid_after_authentication() -> None:
    key = SigningKey()
    response = build_test_client(key).get(
        "/v1/workspaces/not-a-uuid",
        headers=bearer(key.token()),
    )

    assert response.status_code == 422


def test_visible_workspace_uses_user_bearer_and_publishable_apikey() -> None:
    key = SigningKey()
    token = key.token()
    captured_request: httpx.Request | None = None

    def workspace_handler(request: httpx.Request) -> httpx.Response:
        nonlocal captured_request
        captured_request = request
        return httpx.Response(
            200,
            json=[
                {
                    "id": str(WORKSPACE_ID),
                    "name": "Richmond",
                    "created_at": CREATED_AT,
                }
            ],
        )

    response = build_test_client(key, workspace_handler=workspace_handler).get(
        f"/v1/workspaces/{WORKSPACE_ID}?user_id={OTHER_USER_ID}",
        headers=bearer(token),
    )

    assert response.status_code == 200
    assert response.json() == {
        "id": str(WORKSPACE_ID),
        "name": "Richmond",
        "created_at": CREATED_AT,
    }
    assert captured_request is not None
    assert_secret_equal(
        captured_request.headers["authorization"],
        f"Bearer {token}",
    )
    assert captured_request.headers["apikey"] == TEST_PUBLISHABLE_KEY
    assert captured_request.url.params["id"] == f"eq.{WORKSPACE_ID}"
    assert captured_request.url.params["select"] == "id,name,created_at"
    assert "user_id" not in captured_request.url.params
    assert_secret_not_exposed(response.text, token)


def test_zero_rls_visible_rows_returns_generic_not_found() -> None:
    key = SigningKey()
    response = build_test_client(key).get(
        f"/v1/workspaces/{WORKSPACE_ID}",
        headers=bearer(key.token()),
    )

    assert response.status_code == 404
    assert response.json() == {"detail": "Workspace not found."}


def test_absent_and_cross_tenant_workspace_are_indistinguishable() -> None:
    key = SigningKey()
    client = build_test_client(key)
    headers = bearer(key.token())

    absent = client.get(f"/v1/workspaces/{WORKSPACE_ID}", headers=headers)
    inaccessible = client.get(
        "/v1/workspaces/3fbd71e6-bd27-494a-a70f-8cc780d703de",
        headers=headers,
    )

    assert safe_response_snapshot(absent) == safe_response_snapshot(inaccessible)
    assert safe_response_snapshot(absent) == (
        404,
        {"detail": "Workspace not found."},
    )


def test_upstream_authentication_rejection_is_safe() -> None:
    key = SigningKey()

    def workspace_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(401, json={"message": "sensitive upstream detail"})

    response = build_test_client(key, workspace_handler=workspace_handler).get(
        f"/v1/workspaces/{WORKSPACE_ID}",
        headers=bearer(key.token()),
    )

    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"
    assert response.json() == {"detail": "The user session was rejected."}
    assert "sensitive upstream detail" not in response.text


def test_upstream_outage_returns_safe_service_unavailable() -> None:
    key = SigningKey()

    def workspace_handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("private upstream failure", request=request)

    response = build_test_client(key, workspace_handler=workspace_handler).get(
        f"/v1/workspaces/{WORKSPACE_ID}",
        headers=bearer(key.token()),
    )

    assert response.status_code == 503
    assert response.json() == {"detail": "Workspace service is unavailable."}
    assert "private upstream failure" not in response.text


def test_workspace_identity_comes_from_verified_subject() -> None:
    key = SigningKey()
    token = key.token(user_id=TEST_USER_ID)
    observed_authorization = ""

    def workspace_handler(request: httpx.Request) -> httpx.Response:
        nonlocal observed_authorization
        observed_authorization = request.headers["authorization"]
        return httpx.Response(200, json=[])

    response = build_test_client(key, workspace_handler=workspace_handler).get(
        f"/v1/workspaces/{WORKSPACE_ID}?user_id={OTHER_USER_ID}",
        headers=bearer(token),
    )

    assert response.status_code == 404
    assert_secret_equal(observed_authorization, f"Bearer {token}")
