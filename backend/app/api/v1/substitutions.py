"""Substitution suggestions (SUB-01/02/05, brief 005 contract)."""

from __future__ import annotations

from datetime import UTC, datetime

from fastapi import APIRouter, Request

from app.ai.providers.base import AIProvider
from app.core.security import CurrentUser
from app.db.engine import DbSession
from app.domains.substitutions import service
from app.domains.substitutions.schemas import SuggestIn, SuggestOut

router = APIRouter(prefix="/substitutions", tags=["substitutions"])


@router.post("/suggest", response_model=SuggestOut)
async def suggest(
    body: SuggestIn, request: Request, session: DbSession, user: CurrentUser
) -> SuggestOut:
    provider: AIProvider = request.app.state.ai_provider
    return await service.suggest(session, user, body, provider, datetime.now(UTC))
