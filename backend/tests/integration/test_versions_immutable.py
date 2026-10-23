"""Migration 0002: ``recipe_versions`` is append-only at the database level."""

from __future__ import annotations

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import RecipeVersion
from app.scripts.seed import seed_fixtures
from tests.conftest import FIXTURES_DIR


async def _version_id(db_session: AsyncSession) -> str:
    results = await seed_fixtures(db_session, FIXTURES_DIR)
    return str(results[0].version_id)


async def test_trigger_blocks_update(db_session: AsyncSession) -> None:
    version_id = await _version_id(db_session)
    with pytest.raises(DBAPIError, match="append-only"):
        await db_session.execute(
            text("update recipe_versions set servings = 99 where id = :id"), {"id": version_id}
        )
    await db_session.rollback()
    servings = (
        await db_session.execute(
            text("select servings from recipe_versions where id = :id"), {"id": version_id}
        )
    ).scalar_one()
    assert servings == 4


async def test_trigger_blocks_orm_update_and_delete(db_session: AsyncSession) -> None:
    version_id = await _version_id(db_session)
    version = await db_session.get(RecipeVersion, version_id)
    assert version is not None
    version.step_json = []
    with pytest.raises(DBAPIError, match="append-only"):
        await db_session.flush()
    await db_session.rollback()

    version = await db_session.get(RecipeVersion, version_id)
    assert version is not None
    await db_session.delete(version)
    with pytest.raises(DBAPIError, match="append-only"):
        await db_session.flush()
    await db_session.rollback()
    count = (await db_session.execute(text("select count(*) from recipe_versions"))).scalar_one()
    assert count == 5


async def test_trigger_blocks_cascade_delete_from_recipe(db_session: AsyncSession) -> None:
    await _version_id(db_session)
    with pytest.raises(DBAPIError, match="append-only"):
        await db_session.execute(text("delete from recipes"))
    await db_session.rollback()
    assert (await db_session.execute(text("select count(*) from recipes"))).scalar_one() == 5


async def test_operator_unlock_is_transaction_local(db_session: AsyncSession) -> None:
    version_id = await _version_id(db_session)
    await db_session.execute(text("set local souslens.unlock_versions = 'on'"))
    await db_session.execute(
        text("update recipe_versions set servings = 99 where id = :id"), {"id": version_id}
    )
    await db_session.commit()
    servings = (
        await db_session.execute(
            text("select servings from recipe_versions where id = :id"), {"id": version_id}
        )
    ).scalar_one()
    assert servings == 99
    # The unlock died with the transaction.
    with pytest.raises(DBAPIError, match="append-only"):
        await db_session.execute(
            text("update recipe_versions set servings = 4 where id = :id"), {"id": version_id}
        )
    await db_session.rollback()


async def test_truncate_is_blocked_even_with_cascade(db_session: AsyncSession) -> None:
    await _version_id(db_session)
    for sql in (
        "truncate recipe_versions cascade",
        "truncate recipes cascade",  # cascades into recipe_versions
        "truncate users cascade",
    ):
        with pytest.raises(DBAPIError, match="TRUNCATE refused"):
            await db_session.execute(text(sql))
        await db_session.rollback()
    count = (await db_session.execute(text("select count(*) from recipe_versions"))).scalar_one()
    assert count == 5


async def test_truncate_honours_the_operator_unlock(db_session: AsyncSession) -> None:
    await _version_id(db_session)
    await db_session.execute(text("set local souslens.unlock_versions = 'on'"))
    await db_session.execute(text("truncate recipe_versions cascade"))
    await db_session.commit()
    count = (await db_session.execute(text("select count(*) from recipe_versions"))).scalar_one()
    assert count == 0
