from typing import Annotated, Protocol
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request, status

from app.audio_uploads import (
    FinalizedCallUpload,
    InitiateCallUploadRequest,
    SignedCallUpload,
)
from app.auth import BEARER_CHALLENGE, CurrentUser, get_current_user
from app.supabase_data import (
    SupabaseAuthenticationRejected,
    SupabaseDataUnavailable,
)

router = APIRouter(prefix="/v1/workspaces", tags=["audio uploads"])


class AudioUploadService(Protocol):
    async def initiate_upload(
        self,
        *,
        workspace_id: UUID,
        request: InitiateCallUploadRequest,
        current_user: CurrentUser,
    ) -> SignedCallUpload | None: ...

    async def finalize_upload(
        self,
        *,
        workspace_id: UUID,
        call_id: UUID,
        current_user: CurrentUser,
    ) -> FinalizedCallUpload | None: ...


def get_audio_upload_service(request: Request) -> AudioUploadService:
    return request.app.state.audio_upload_client


@router.post(
    "/{workspace_id}/calls/uploads",
    response_model=SignedCallUpload,
    status_code=status.HTTP_201_CREATED,
)
async def initiate_call_upload(
    workspace_id: UUID,
    upload_request: InitiateCallUploadRequest,
    current_user: Annotated[CurrentUser, Depends(get_current_user)],
    upload_service: Annotated[AudioUploadService, Depends(get_audio_upload_service)],
) -> SignedCallUpload:
    try:
        upload = await upload_service.initiate_upload(
            workspace_id=workspace_id,
            request=upload_request,
            current_user=current_user,
        )
    except SupabaseAuthenticationRejected as exc:
        raise _session_rejected() from exc
    except SupabaseDataUnavailable as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Upload service is unavailable.",
        ) from exc

    if upload is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Workspace not found.",
        )
    return upload


@router.post(
    "/{workspace_id}/calls/{call_id}/complete",
    response_model=FinalizedCallUpload,
)
async def complete_call_upload(
    workspace_id: UUID,
    call_id: UUID,
    current_user: Annotated[CurrentUser, Depends(get_current_user)],
    upload_service: Annotated[AudioUploadService, Depends(get_audio_upload_service)],
) -> FinalizedCallUpload:
    try:
        upload = await upload_service.finalize_upload(
            workspace_id=workspace_id,
            call_id=call_id,
            current_user=current_user,
        )
    except SupabaseAuthenticationRejected as exc:
        raise _session_rejected() from exc
    except SupabaseDataUnavailable as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Upload service is unavailable.",
        ) from exc

    if upload is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Call upload not found.",
        )
    return upload


def _session_rejected() -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="The user session was rejected.",
        headers=BEARER_CHALLENGE,
    )
