from typing import Any
from uuid import UUID

import httpx2 as httpx
from pydantic import BaseModel, ValidationError

from app.auth import CurrentUser
from app.config import Settings


class WorkspaceRecord(BaseModel):
    id: UUID
    name: str
    created_at: str


class SupabaseAuthenticationRejected(Exception):
    """Supabase rejected the user-scoped Data API credential."""


class SupabaseDataUnavailable(Exception):
    """Supabase Data API could not provide a safe, valid response."""


class SupabaseWorkspaceClient:
    def __init__(
        self,
        settings: Settings,
        *,
        timeout_seconds: float = 5.0,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self._settings = settings
        self._timeout = httpx.Timeout(timeout_seconds)
        self._transport = transport

    async def get_visible_workspace(
        self,
        *,
        workspace_id: UUID,
        current_user: CurrentUser,
    ) -> WorkspaceRecord | None:
        try:
            rest_url = self._settings.supabase_rest_url
            publishable_key = self._settings.require_publishable_key()
        except RuntimeError as exc:
            raise SupabaseDataUnavailable from exc

        headers = {
            "apikey": publishable_key,
            "Authorization": f"Bearer {current_user.access_token}",
            "Accept": "application/json",
        }
        params = {
            "select": "id,name,created_at",
            "id": f"eq.{workspace_id}",
            "limit": "1",
        }

        try:
            async with httpx.AsyncClient(
                timeout=self._timeout,
                transport=self._transport,
            ) as client:
                response = await client.get(
                    f"{rest_url}/workspaces",
                    headers=headers,
                    params=params,
                )
        except httpx.HTTPError as exc:
            raise SupabaseDataUnavailable from exc

        if response.status_code in {401, 403}:
            raise SupabaseAuthenticationRejected
        if response.status_code < 200 or response.status_code >= 300:
            raise SupabaseDataUnavailable

        try:
            payload: Any = response.json()
            if not isinstance(payload, list):
                raise SupabaseDataUnavailable
            if not payload:
                return None
            return WorkspaceRecord.model_validate(payload[0])
        except (ValueError, TypeError, ValidationError, IndexError) as exc:
            raise SupabaseDataUnavailable from exc
