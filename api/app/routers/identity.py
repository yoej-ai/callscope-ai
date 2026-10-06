from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends
from pydantic import BaseModel

from app.auth import CurrentUser, get_current_user

router = APIRouter(prefix="/v1", tags=["identity"])


class CurrentUserResponse(BaseModel):
    user_id: UUID
    role: str


@router.get("/me", response_model=CurrentUserResponse)
async def get_me(
    current_user: Annotated[CurrentUser, Depends(get_current_user)],
) -> CurrentUserResponse:
    return CurrentUserResponse(
        user_id=current_user.user_id,
        role=current_user.role,
    )
