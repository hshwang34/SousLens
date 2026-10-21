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
) -> T:
    stmt = select(model).where(model.id == resource_id, model.owner_user_id == owner_user_id)
    row = (await session.execute(stmt)).scalar_one_or_none()
    if row is None:
        raise NotFound(f"{label} not found")
    return row
