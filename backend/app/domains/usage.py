"""Durable per-user rate limits (brief 005 security review).

Counts come from ``usage_events``, which is keyed on the user only, so deleting or recreating
a cooking session never resets a budget. :func:`reserve` counts and inserts under a per-user
advisory lock, in the caller's transaction: if anything later in the request fails, the
reservation rolls back with it; the caller commits it before any slow provider call.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import RateLimited
from app.db.models import UsageEvent
from app.domains.pantry.service import lock_user

ASK = "ask"
SESSION_CREATED = "session_created"


async def count_recent(
    session: AsyncSession, user_id: uuid.UUID, kind: str, since: datetime
) -> int:
    return int(
        await session.scalar(
            select(func.count())
            .select_from(UsageEvent)
            .where(
                UsageEvent.user_id == user_id,
                UsageEvent.kind == kind,
                UsageEvent.created_at > since,
            )
        )
        or 0
    )


async def reserve(
    session: AsyncSession,
    user_id: uuid.UUID,
    kind: str,
    *,
    limit: int,
    window: timedelta,
    now: datetime,
    message: str,
) -> None:
    await lock_user(session, user_id, f"usage:{kind}")
    if await count_recent(session, user_id, kind, now - window) >= limit:
        raise RateLimited(message)
    session.add(UsageEvent(user_id=user_id, kind=kind, created_at=now))
    await session.flush()
