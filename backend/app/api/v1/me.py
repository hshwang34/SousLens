from __future__ import annotations

from fastapi import APIRouter

from app.core.security import CurrentUser
from app.domains.users.schemas import UserOut

router = APIRouter(tags=["me"])


@router.get("/me", response_model=UserOut)
async def me(user: CurrentUser) -> UserOut:
    return UserOut.from_model(user)
