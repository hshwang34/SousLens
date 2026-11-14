"""Brief 015: fictional creator personas seeded by ``make seed``."""

from __future__ import annotations

from httpx import AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import Recipe, User
from app.scripts.seed import PERSONA_PROVIDER, load_fixtures, seed_fixtures
from tests.conftest import FIXTURES_DIR, dev_sign_in


def test_persona_fixtures_are_marked_fictional() -> None:
    fixtures = load_fixtures(FIXTURES_DIR, "seeded_creators")
    assert len(fixtures) >= 12
    handles = {f.creator.handle for f in fixtures}
    assert len(handles) == 6
    for fixture in fixtures:
        assert fixture.creator.handle
        assert (fixture.creator.bio or "").startswith("Sample creator. ")
    base = {f.slug for f in load_fixtures(FIXTURES_DIR)}
    assert base.isdisjoint({f.slug for f in fixtures})


async def test_personas_seed_idempotently_and_cannot_sign_in(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    first = await seed_fixtures(db_session, FIXTURES_DIR, include_creators=True)
    again = await seed_fixtures(db_session, FIXTURES_DIR, include_creators=True)
    assert len(first) == len(again)
    assert not any(r.created_recipe or r.created_version for r in again)

    personas = (
        (await db_session.execute(select(User).where(User.auth_provider == PERSONA_PROVIDER)))
        .scalars()
        .all()
    )
    assert len(personas) == 6
    assert all(p.email is None for p in personas)
    total = (await db_session.execute(select(func.count()).select_from(Recipe))).scalar_one()
    assert total == len(first)

    headers = {"Authorization": f"Bearer {await dev_sign_in(client, 'alice@example.com')}"}
    items = (await client.get("/v1/creators/suggested?cuisines=korean", headers=headers)).json()
    top = items["items"][0]
    assert top["display_name"] == "Mina Cho"
    assert top["bio"].startswith("Sample creator. ")
