"""Owned-resource access: a row that belongs to someone else is indistinguishable from a
missing one (404, no metadata leak — PRD §11.1, SEC-01)."""

from __future__ import annotations

import uuid
from typing import Protocol

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import NotFound


class Owned(Protocol):
    id: uuid.UUID
    owner_user_id: uuid.UUID


async def get_owned_or_404[T: Owned](
    session: AsyncSession,
    model: type[T],
    resource_id: uuid.UUID,
    owner_user_id: uuid.UUID,
    *,
    label: str = "Resource",
    for_update: bool | dict[str, bool] = False,
) -> T:
    """``for_update`` locks the row in the same query (``{"read": True}`` for FOR SHARE), so a
    row deleted concurrently is the same 404, never a stale instance."""
    stmt = select(model).where(model.id == resource_id, model.owner_user_id == owner_user_id)
    if for_update:
        read = isinstance(for_update, dict) and for_update.get("read", False)
        stmt = stmt.with_for_update(read=read).execution_options(populate_existing=True)
    row = (await session.execute(stmt)).scalar_one_or_none()
    if row is None:
        raise NotFound(f"{label} not found")
    return row
