"""``GET /v1/ai/status`` (brief 007): whether answers are live right now, for the app banner.

``live=false`` with an ``ai_notice`` means a budget cap is reached and AI features answer from
the labelled demo path. ``video_extraction_enabled`` is the monthly soft-degrade flag (Slice 5).
Under ``AI_PROVIDER=mock`` the provider is ``mock`` and nothing is live.
"""

from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, Request
from pydantic import BaseModel

from app.ai.budget import CostGuard
from app.ai.notice import AINotice, notice_field
from app.ai.providers.gemini import GeminiProvider
from app.core.security import CurrentUser

router = APIRouter(prefix="/ai", tags=["ai"])


class AIStatusOut(BaseModel):
    provider: Literal["mock", "gemini"]
    live: bool
    video_extraction_enabled: bool
    ai_notice: AINotice | None = notice_field()


@router.get("/status", response_model=AIStatusOut)
async def ai_status(request: Request, user: CurrentUser) -> AIStatusOut:
    provider = request.app.state.ai_provider
    if not isinstance(provider, GeminiProvider):
        return AIStatusOut(provider="mock", live=False, video_extraction_enabled=True)
    guard: CostGuard = request.app.state.cost_guard
    status = await guard.status(user.id)
    return AIStatusOut(
        provider="gemini",
        live=status.live and provider.configured,
        video_extraction_enabled=status.video_extraction_enabled,
        ai_notice=AINotice(reason=status.reason) if status.reason else None,
    )
