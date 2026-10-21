"""DB-level CHECK constraints added in migration 0001."""

from __future__ import annotations

import pytest
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import CookingSession, SessionEvent, Timer
from app.domains.users import service as users_service
from app.scripts.seed import seed_fixtures
from tests.conftest import FIXTURES_DIR


async def _session(db_session: AsyncSession) -> CookingSession:
    await seed_fixtures(db_session, FIXTURES_DIR)
    user = await users_service.get_or_create_by_email(
        db_session, email="c@example.com", display_name=None, auth_provider="dev"
    )
    version_id = (
        await db_session.execute(text("select id from recipe_versions limit 1"))
    ).scalar_one()
    session = CookingSession(owner_user_id=user.id, recipe_version_id=version_id)
    db_session.add(session)
    await db_session.flush()
    return session


@pytest.mark.parametrize("field", ["revision", "step_index"])
async def test_cooking_session_counters_cannot_go_negative(
    db_session: AsyncSession, field: str
) -> None:
    session = await _session(db_session)
    setattr(session, field, -1)
    with pytest.raises(IntegrityError, match=f"ck_cooking_sessions_{field}_non_negative"):
        await db_session.flush()
    await db_session.rollback()


async def test_session_event_sequence_cannot_go_negative(db_session: AsyncSession) -> None:
    session = await _session(db_session)
    db_session.add(SessionEvent(session_id=session.id, sequence=-1, type="x"))
    with pytest.raises(IntegrityError, match="ck_session_events_sequence_non_negative"):
        await db_session.flush()
    await db_session.rollback()


async def test_timer_step_index_cannot_go_negative(db_session: AsyncSession) -> None:
    session = await _session(db_session)
    now = (await db_session.execute(text("select now()"))).scalar_one()
    db_session.add(Timer(session_id=session.id, step_index=-1, label="simmer", target_at=now))
    with pytest.raises(IntegrityError, match="ck_timers_step_index_non_negative"):
        await db_session.flush()
    await db_session.rollback()
