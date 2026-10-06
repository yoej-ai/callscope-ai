from typing import Annotated, Protocol
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request, status

from app.auth import BEARER_CHALLENGE, CurrentUser, get_current_user
from app.supabase_data import (
    SupabaseAuthenticationRejected,
    SupabaseDataUnavailable,
    WorkspaceRecord,
)

router = APIRouter(prefix="/v1/workspaces", tags=["workspaces"])


class WorkspaceReader(Protocol):
    async def get_visible_workspace(
        self,
        *,
        workspace_id: UUID,
        current_user: CurrentUser,
    ) -> WorkspaceRecord | None: ...


def get_workspace_reader(request: Request) -> WorkspaceReader:
    return request.app.state.workspace_client


@router.get("/{workspace_id}", response_model=WorkspaceRecord)
async def get_workspace(
    workspace_id: UUID,
    current_user: Annotated[CurrentUser, Depends(get_current_user)],
    workspace_reader: Annotated[WorkspaceReader, Depends(get_workspace_reader)],
) -> WorkspaceRecord:
    try:
        workspace = await workspace_reader.get_visible_workspace(
            workspace_id=workspace_id,
            current_user=current_user,
        )
    except SupabaseAuthenticationRejected as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="The user session was rejected.",
            headers=BEARER_CHALLENGE,
        ) from exc
    except SupabaseDataUnavailable as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Workspace service is unavailable.",
        ) from exc

    if workspace is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Workspace not found.",
        )
    return workspace
