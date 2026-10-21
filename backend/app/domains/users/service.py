"""User lookup/creation. Dev provider keys users by email (DECISIONS #5)."""

from __future__ import annotations

import uuid

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import User


def display_name_from_email(email: str) -> str:
    local = email.split("@", 1)[0].strip()
    return local or email


async def get_by_id(session: AsyncSession, user_id: uuid.UUID) -> User | None:
    return await session.get(User, user_id)


async def find_by_subject(
    session: AsyncSession, *, auth_provider: str, subject: str
) -> User | None:
    result = await session.execute(
        select(User).where(User.auth_provider == auth_provider, User.auth_subject == subject)
    )
    return result.scalar_one_or_none()


async def get_or_create_by_email(
    session: AsyncSession,
    *,
    email: str,
    display_name: str | None,
    auth_provider: str,
    user_id: uuid.UUID | None = None,
) -> User:
    """Find-or-create keyed by ``(auth_provider, email)``.

    Two first logins for the same email can race; the loser hits the unique constraint inside a
    SAVEPOINT, rolls back only that insert and re-selects the winner's row.
    """
    normalized = email.strip().lower()
    user = await find_by_subject(session, auth_provider=auth_provider, subject=normalized)
    if user is not None:
        return user
    candidate = User(
        id=user_id or uuid.uuid4(),
        auth_provider=auth_provider,
        auth_subject=normalized,
        email=normalized,
        display_name=(display_name or "").strip() or display_name_from_email(normalized),
    )
    try:
        async with session.begin_nested():
            session.add(candidate)
            await session.flush()
    except IntegrityError:
        # The savepoint rollback already expunged ``candidate``; adopt the winner's row.
        user = await find_by_subject(session, auth_provider=auth_provider, subject=normalized)
        if user is None:
            raise
        return user
    return candidate
