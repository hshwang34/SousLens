from __future__ import annotations

from typing import Literal

from fastapi import APIRouter
from pydantic import BaseModel

from app.core.security import SettingsDep

router = APIRouter(tags=["health"])


class HealthResponse(BaseModel):
    status: Literal["ok"] = "ok"
    version: str
    ai_provider: str


@router.get("/health", response_model=HealthResponse)
async def health(settings: SettingsDep) -> HealthResponse:
    return HealthResponse(
        version=settings.app_version,
        ai_provider=settings.ai_provider,
    )
