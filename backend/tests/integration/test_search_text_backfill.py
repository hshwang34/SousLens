"""Fix round 1 item 9: migration 0002's SQL backfill of ``search_text`` == ``search_text_for``."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import ModuleType

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.domains.recipes.drafts import search_text_for
from app.domains.users import service as users_service
from app.scripts.seed import load_fixtures, seed_fixtures
from tests.conftest import BACKEND_DIR, FIXTURES_DIR

MIGRATION = BACKEND_DIR / "app/db/migrations/versions/0002_versions_append_only_search.py"


def _migration() -> ModuleType:
    spec = importlib.util.spec_from_file_location("migration_0002", Path(MIGRATION))
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


async def _sql_search_text(db_session: AsyncSession) -> dict[str, tuple[str, str]]:
    expr = _migration().SEARCH_TEXT_SQL
    rows = await db_session.execute(
        text(
            f"select v.id::text, v.search_text, {expr} as backfill "
            "from recipe_versions v join recipes r on r.id = v.recipe_id"
        )
    )
    return {vid: (stored, backfill) for vid, stored, backfill in rows}


async def test_backfill_sql_matches_python_for_every_seeded_fixture(
    db_session: AsyncSession,
) -> None:
    results = {r.slug: str(r.version_id) for r in await seed_fixtures(db_session, FIXTURES_DIR)}
    by_version = await _sql_search_text(db_session)
    assert len(by_version) == 6  # gochujang v1 + v2
    for fixture in load_fixtures(FIXTURES_DIR):
        stored, backfill = by_version[results[fixture.slug]]
        expected = search_text_for(
            fixture.title, [i.model_dump(mode="json") for i in fixture.ingredients]
        )
        assert stored == expected, fixture.slug
        assert backfill == expected, fixture.slug


async def test_backfill_sql_matches_python_on_whitespace_and_empty_names(
    db_session: AsyncSession,
) -> None:
    owner = await users_service.get_or_create_by_email(
        db_session, email="edge@example.com", display_name=None, auth_provider="dev"
    )
    title = "  Spaced\tTitle \n"
    ingredients = [
        {"id": "a", "name": "  Gochujang "},
        {"id": "b", "name": ""},
        {"id": "c", "name": "   "},
        {"id": "d"},
        {"id": "e", "name": None},
        {"id": "f", "name": "\tGreen  Onion\r\n"},
        {"id": "g", "name": "ÉCHALOTE"},
    ]
    recipe_id = (
        await db_session.execute(
            text(
                "insert into recipes (id, owner_user_id, slug, visibility, title, tags) "
                "values (gen_random_uuid(), :o, 'edge', 'public', :t, '{}') returning id"
            ),
            {"o": owner.id, "t": title},
        )
    ).scalar_one()
    await db_session.execute(
        text(
            "insert into recipe_versions (id, recipe_id, version_number, servings, "
            "ingredient_json, step_json, warning_json) "
            "values (gen_random_uuid(), :r, 1, 1, cast(:ing as jsonb), '[]', '{}')"
        ),
        {"r": recipe_id, "ing": json.dumps(ingredients)},
    )
    ((_, backfill),) = (await _sql_search_text(db_session)).values()
    expected = search_text_for(title, ingredients)
    assert expected == "spaced\ttitle gochujang green  onion échalote"
    assert backfill == expected
    await db_session.rollback()


def test_python_rule_drops_empty_parts_and_never_double_spaces() -> None:
    assert search_text_for(" A ", [{"name": ""}, {"name": " b "}, {}]) == "a b"
    assert search_text_for(None, []) == ""
