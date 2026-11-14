"""For You and Following feeds (brief 015). Search stays on ``GET /recipes``."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Query

from app.core.security import CurrentUser
from app.db.engine import DbSession
from app.domains.feed import service
from app.domains.feed.schemas import FeedPage

router = APIRouter(prefix="/feed", tags=["feed"])

Cursor = Annotated[str | None, Query(max_length=16)]
Limit = Annotated[int, Query(ge=1, le=service.MAX_LIMIT)]


@router.get("/for-you", response_model=FeedPage)
async def for_you(
    session: DbSession, user: CurrentUser, cursor: Cursor = None, limit: Limit = 20
) -> FeedPage:
    return await service.for_you(session, user, cursor=cursor, limit=limit, now=datetime.now(UTC))


@router.get("/following", response_model=FeedPage)
async def following(
    session: DbSession, user: CurrentUser, cursor: Cursor = None, limit: Limit = 20
) -> FeedPage:
    return await service.following(session, user, cursor=cursor, limit=limit)
