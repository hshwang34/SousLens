"""``GET /v1/ai/status`` (brief 007): whether answers are live right now, for the app banner.
``POST /v1/ai/live-token`` (brief 016): a single-use Gemini Live token for the live pantry scan.

``live=false`` with an ``ai_notice`` means a budget cap is reached and AI features answer from
the labelled demo path. ``video_extraction_enabled`` is the monthly soft-degrade flag (Slice 5).
Under ``AI_PROVIDER=mock`` the provider is ``mock`` and nothing is live.
"""

from __future__ import annotations

from datetime import datetime
from typing import Annotated, Literal

from fastapi import APIRouter, Request, Response
from pydantic import BaseModel, Field, StringConstraints

from app.ai.budget import CostGuard
from app.ai.live_pantry import MAX_BASKET_NAMES, MAX_NAME_CHARS, issue_live_token
from app.ai.notice import AINotice, notice_field
from app.ai.providers.gemini import GeminiProvider
from app.core.errors import ProviderNotConfigured
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


class LiveTokenIn(BaseModel):
    # Names a rotated session already reported. Untrusted: cleaned and quoted as data.
    already_in_basket: list[Annotated[str, StringConstraints(max_length=MAX_NAME_CHARS)]] = Field(
        default_factory=list, max_length=MAX_BASKET_NAMES
    )


class LiveTokenOut(BaseModel):
    token: str | None = Field(repr=False)  # a credential: never in a repr or a log
    model: str
    expires_at: datetime | None
    new_session_expires_at: datetime | None
    max_session_seconds: int
    nudge_text: str
    nudge_every_frames: int
    frame_max_fps: float
    demo: bool
    ai_notice: AINotice | None = notice_field()


@router.post("/live-token", response_model=LiveTokenOut)
async def live_token(
    request: Request, response: Response, user: CurrentUser, body: LiveTokenIn | None = None
) -> LiveTokenOut:
    response.headers["Cache-Control"] = "no-store"  # carries a credential
    settings = request.app.state.settings
    out = LiveTokenOut(
        token=None,
        model=settings.gemini_model_live,
        expires_at=None,
        new_session_expires_at=None,
        max_session_seconds=settings.live_max_session_seconds,
        nudge_text=settings.live_nudge_text,
        nudge_every_frames=settings.live_nudge_every_frames,
        frame_max_fps=settings.live_frame_max_fps,
        demo=True,
    )
    if not isinstance(request.app.state.ai_provider, GeminiProvider):
        return out  # AI_PROVIDER=mock: the app replays its labelled demo script
    minter = request.app.state.live_token_minter
    if minter is None:
        raise ProviderNotConfigured("Gemini live scan is not configured. Set GEMINI_API_KEY.")
    result = await issue_live_token(
        guard=request.app.state.cost_guard,
        minter=minter,
        settings=settings,
        user_id=user.id,
        already_in_basket=body.already_in_basket if body else [],
    )
    if result.minted is None:
        return out.model_copy(update={"ai_notice": result.notice})
    return out.model_copy(
        update={
            "token": result.minted.token,
            "expires_at": result.minted.expire_time,
            "new_session_expires_at": result.minted.new_session_expire_time,
            "demo": False,
        }
    )
