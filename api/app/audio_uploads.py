from typing import Any, Literal
from urllib.parse import parse_qs, quote, urlsplit
from uuid import UUID

import httpx2 as httpx
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

from app.auth import CurrentUser
from app.config import Settings
from app.supabase_data import (
    SupabaseAuthenticationRejected,
    SupabaseDataUnavailable,
)

AUDIO_BUCKET = "call-audio"
MAX_AUDIO_SIZE_BYTES = 26_214_400
SIGNED_UPLOAD_EXPIRES_SECONDS = 7_200
RECONCILIATION_BATCH_LIMIT = 20
CONTENT_TYPE_BY_EXTENSION = {
    ".mp3": "audio/mpeg",
    ".mp4": "audio/mp4",
    ".m4a": "audio/x-m4a",
    ".wav": "audio/wav",
    ".webm": "audio/webm",
    ".ogg": "audio/ogg",
}
SUPPORTED_AUDIO_CONTENT_TYPES = frozenset(CONTENT_TYPE_BY_EXTENSION.values())


class InitiateCallUploadRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    filename: str = Field(min_length=1, max_length=255)
    content_type: str = Field(min_length=1, max_length=100)
    size_bytes: int = Field(strict=True, ge=1, le=MAX_AUDIO_SIZE_BYTES)

    @field_validator("filename")
    @classmethod
    def validate_filename(cls, value: str) -> str:
        normalized = value.strip()
        if (
            not normalized
            or "/" in normalized
            or "\\" in normalized
            or any(ord(character) < 32 for character in normalized)
        ):
            raise ValueError("filename must be a plain display filename")

        extension = audio_extension(normalized)
        if extension not in CONTENT_TYPE_BY_EXTENSION:
            raise ValueError("filename extension is not supported")
        if len(normalized) <= len(extension):
            raise ValueError("filename must include a name before its extension")
        return normalized

    @field_validator("content_type")
    @classmethod
    def validate_content_type(cls, value: str) -> str:
        normalized = value.strip().lower()
        if normalized not in SUPPORTED_AUDIO_CONTENT_TYPES:
            raise ValueError("content type is not supported")
        return normalized

    @field_validator("content_type")
    @classmethod
    def validate_extension_matches_content_type(
        cls,
        value: str,
        info: Any,
    ) -> str:
        filename = info.data.get("filename")
        if isinstance(filename, str):
            expected = CONTENT_TYPE_BY_EXTENSION[audio_extension(filename)]
            if value != expected:
                raise ValueError("filename extension and content type do not match")
        return value


class PendingCallUpload(BaseModel):
    call_id: UUID
    workspace_id: UUID
    storage_bucket: str
    storage_path: str
    content_type: str
    size_bytes: int


class SignedCallUpload(BaseModel):
    call_id: UUID
    bucket: str
    path: str
    upload_token: str = Field(repr=False)
    expires_in_seconds: int = SIGNED_UPLOAD_EXPIRES_SECONDS


class FinalizedCallUpload(BaseModel):
    call_id: UUID
    status: str


class ReconciledCallUpload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    call_id: UUID
    outcome: Literal["deleted", "uploaded", "failed"]


class UploadReconciliationResult(BaseModel):
    processed: int = Field(ge=0, le=RECONCILIATION_BATCH_LIMIT)
    uploaded: int = Field(ge=0, le=RECONCILIATION_BATCH_LIMIT)
    deleted: int = Field(ge=0, le=RECONCILIATION_BATCH_LIMIT)
    failed: int = Field(ge=0, le=RECONCILIATION_BATCH_LIMIT)
    results: list[ReconciledCallUpload]


def audio_extension(filename: str) -> str:
    dot_index = filename.rfind(".")
    if dot_index < 0:
        return ""
    return filename[dot_index:].lower()


def encode_storage_path(bucket: str, path: str) -> str:
    return "/".join(quote(segment, safe="") for segment in (bucket, *path.split("/")))


class SupabaseAudioUploadClient:
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

    async def initiate_upload(
        self,
        *,
        workspace_id: UUID,
        request: InitiateCallUploadRequest,
        current_user: CurrentUser,
    ) -> SignedCallUpload | None:
        rest_url, storage_url, headers = self._connection(current_user)

        try:
            async with httpx.AsyncClient(
                timeout=self._timeout,
                transport=self._transport,
            ) as client:
                pending = await self._create_pending_upload(
                    client,
                    rest_url=rest_url,
                    headers=headers,
                    workspace_id=workspace_id,
                    request=request,
                )
                if pending is None:
                    return None

                try:
                    upload_token = await self._create_signed_upload_token(
                        client,
                        storage_url=storage_url,
                        headers=headers,
                        pending=pending,
                    )
                except (
                    httpx.HTTPError,
                    SupabaseAuthenticationRejected,
                    SupabaseDataUnavailable,
                ):
                    await self._abort_pending_upload(
                        client,
                        rest_url=rest_url,
                        headers=headers,
                        workspace_id=workspace_id,
                        call_id=pending.call_id,
                    )
                    raise
        except httpx.HTTPError as exc:
            raise SupabaseDataUnavailable from exc

        return SignedCallUpload(
            call_id=pending.call_id,
            bucket=pending.storage_bucket,
            path=pending.storage_path,
            upload_token=upload_token,
        )

    async def finalize_upload(
        self,
        *,
        workspace_id: UUID,
        call_id: UUID,
        current_user: CurrentUser,
    ) -> FinalizedCallUpload | None:
        rest_url, _, headers = self._connection(current_user)
        try:
            async with httpx.AsyncClient(
                timeout=self._timeout,
                transport=self._transport,
            ) as client:
                response = await client.post(
                    f"{rest_url}/rpc/finalize_call_upload",
                    headers=headers,
                    json={
                        "p_workspace_id": str(workspace_id),
                        "p_call_id": str(call_id),
                    },
                )
        except httpx.HTTPError as exc:
            raise SupabaseDataUnavailable from exc

        self._raise_for_upstream_status(response)
        try:
            payload: Any = response.json()
            if not isinstance(payload, list):
                raise SupabaseDataUnavailable
            if not payload:
                return None
            finalized = FinalizedCallUpload.model_validate(payload[0])
            if finalized.call_id != call_id or finalized.status != "uploaded":
                raise SupabaseDataUnavailable
            return finalized
        except (ValueError, TypeError, ValidationError, IndexError) as exc:
            raise SupabaseDataUnavailable from exc

    async def reconcile_uploads(
        self,
        *,
        workspace_id: UUID,
        current_user: CurrentUser,
    ) -> UploadReconciliationResult | None:
        rest_url, _, headers = self._connection(current_user)
        try:
            async with httpx.AsyncClient(
                timeout=self._timeout,
                transport=self._transport,
            ) as client:
                if not await self._workspace_is_visible(
                    client,
                    rest_url=rest_url,
                    headers=headers,
                    workspace_id=workspace_id,
                ):
                    return None
                response = await client.post(
                    f"{rest_url}/rpc/reconcile_stale_call_uploads",
                    headers=headers,
                    json={
                        "p_workspace_id": str(workspace_id),
                        "p_limit": RECONCILIATION_BATCH_LIMIT,
                    },
                )
        except httpx.HTTPError as exc:
            raise SupabaseDataUnavailable from exc

        self._raise_for_upstream_status(response)
        try:
            payload: Any = response.json()
            if not isinstance(payload, list) or len(payload) > RECONCILIATION_BATCH_LIMIT:
                raise SupabaseDataUnavailable
            results = [ReconciledCallUpload.model_validate(item) for item in payload]
            if len({item.call_id for item in results}) != len(results):
                raise SupabaseDataUnavailable
        except (ValueError, TypeError, ValidationError) as exc:
            raise SupabaseDataUnavailable from exc

        return UploadReconciliationResult(
            processed=len(results),
            uploaded=sum(item.outcome == "uploaded" for item in results),
            deleted=sum(item.outcome == "deleted" for item in results),
            failed=sum(item.outcome == "failed" for item in results),
            results=results,
        )

    async def _workspace_is_visible(
        self,
        client: httpx.AsyncClient,
        *,
        rest_url: str,
        headers: dict[str, str],
        workspace_id: UUID,
    ) -> bool:
        response = await client.get(
            f"{rest_url}/workspaces",
            headers=headers,
            params={
                "id": f"eq.{workspace_id}",
                "select": "id",
                "limit": "1",
            },
        )
        self._raise_for_upstream_status(response)

        try:
            payload: Any = response.json()
            if not isinstance(payload, list):
                raise SupabaseDataUnavailable
            if not payload:
                return False
            if (
                len(payload) != 1
                or not isinstance(payload[0], dict)
                or set(payload[0]) != {"id"}
                or not isinstance(payload[0]["id"], str)
                or UUID(payload[0]["id"]) != workspace_id
            ):
                raise SupabaseDataUnavailable
        except (ValueError, TypeError) as exc:
            raise SupabaseDataUnavailable from exc
        return True

    def _connection(
        self,
        current_user: CurrentUser,
    ) -> tuple[str, str, dict[str, str]]:
        try:
            rest_url = self._settings.supabase_rest_url
            storage_url = self._settings.supabase_storage_url
            publishable_key = self._settings.require_publishable_key()
        except RuntimeError as exc:
            raise SupabaseDataUnavailable from exc

        return (
            rest_url,
            storage_url,
            {
                "apikey": publishable_key,
                "Authorization": f"Bearer {current_user.access_token}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
        )

    async def _create_pending_upload(
        self,
        client: httpx.AsyncClient,
        *,
        rest_url: str,
        headers: dict[str, str],
        workspace_id: UUID,
        request: InitiateCallUploadRequest,
    ) -> PendingCallUpload | None:
        response = await client.post(
            f"{rest_url}/rpc/create_call_upload",
            headers=headers,
            json={
                "p_workspace_id": str(workspace_id),
                "p_original_filename": request.filename,
                "p_content_type": request.content_type,
                "p_size_bytes": request.size_bytes,
            },
        )
        self._raise_for_upstream_status(response)

        try:
            payload: Any = response.json()
            if not isinstance(payload, list):
                raise SupabaseDataUnavailable
            if not payload:
                return None
            pending = PendingCallUpload.model_validate(payload[0])
            expected_path = (
                f"{workspace_id}/{pending.call_id}/source"
                f"{audio_extension(request.filename)}"
            )
            if (
                pending.workspace_id != workspace_id
                or pending.storage_bucket != AUDIO_BUCKET
                or pending.storage_path != expected_path
                or pending.content_type != request.content_type
                or pending.size_bytes != request.size_bytes
            ):
                raise SupabaseDataUnavailable
            return pending
        except (ValueError, TypeError, ValidationError, IndexError) as exc:
            raise SupabaseDataUnavailable from exc

    async def _create_signed_upload_token(
        self,
        client: httpx.AsyncClient,
        *,
        storage_url: str,
        headers: dict[str, str],
        pending: PendingCallUpload,
    ) -> str:
        encoded_path = encode_storage_path(
            pending.storage_bucket,
            pending.storage_path,
        )
        expected_path = f"/object/upload/sign/{encoded_path}"
        response = await client.post(
            f"{storage_url}{expected_path}",
            headers=headers,
            json={},
        )
        self._raise_for_upstream_status(response)

        try:
            payload: Any = response.json()
            signed_path = payload.get("url") if isinstance(payload, dict) else None
            if not isinstance(signed_path, str):
                raise SupabaseDataUnavailable
            parsed = urlsplit(signed_path)
            tokens = parse_qs(parsed.query).get("token", [])
            if (
                parsed.scheme
                or parsed.netloc
                or parsed.path != expected_path
                or len(tokens) != 1
                or not tokens[0]
            ):
                raise SupabaseDataUnavailable
            return tokens[0]
        except (ValueError, TypeError) as exc:
            raise SupabaseDataUnavailable from exc

    async def _abort_pending_upload(
        self,
        client: httpx.AsyncClient,
        *,
        rest_url: str,
        headers: dict[str, str],
        workspace_id: UUID,
        call_id: UUID,
    ) -> None:
        try:
            await client.post(
                f"{rest_url}/rpc/abort_call_upload",
                headers=headers,
                json={
                    "p_workspace_id": str(workspace_id),
                    "p_call_id": str(call_id),
                },
            )
        except httpx.HTTPError:
            pass

    @staticmethod
    def _raise_for_upstream_status(response: httpx.Response) -> None:
        if response.status_code == 401:
            raise SupabaseAuthenticationRejected
        if response.status_code < 200 or response.status_code >= 300:
            raise SupabaseDataUnavailable
