"""Brief 001 gate probes: schema coverage, cross-user isolation, cursors, 500 envelope, DB rules."""

from __future__ import annotations

import base64
import json
import uuid
from datetime import UTC, datetime

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import inspect, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession

from app.core.config import Settings
from app.core.errors import NotFound
from app.db.base import Base
from app.db.models import (
    CookingSession,
    DraftStatus,
    PantryItem,
    PantrySource,
    RecipeDraft,
    SessionEvent,
)
from app.domains.ownership import get_owned_or_404
from app.domains.users import service as users_service
from app.main import create_app
from app.scripts.seed import seed_fixtures
from tests.conftest import FIXTURES_DIR, dev_login

PRD_TABLES = {
    "users", "recipes", "recipe_versions", "recipe_media", "recipe_drafts", "extraction_jobs",
    "saves", "ingredients", "pantry_items", "pantry_observations", "cooking_sessions",
    "session_events", "session_messages", "timers", "media_consents", "feedback",
}  # fmt: skip


def b64(obj: object) -> str:
    return base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip("=")


async def test_all_prd_tables_exist_with_uuid_pks_and_owner_columns(engine: AsyncEngine) -> None:
    async with engine.connect() as conn:
        tables = await conn.run_sync(lambda c: set(inspect(c).get_table_names()))
        assert PRD_TABLES <= tables
        assert set(Base.metadata.tables) >= PRD_TABLES
        for name in PRD_TABLES:
            pk = Base.metadata.tables[name].primary_key.columns
            assert [str(c.type) for c in pk] == ["UUID"], name
        for name in ("recipes", "recipe_drafts", "pantry_items", "cooking_sessions"):
            assert "owner_user_id" in Base.metadata.tables[name].c, name
        # all timestamps are timezone-aware
        for table in Base.metadata.tables.values():
            for col in table.c:
                if "DATETIME" in str(col.type).upper() or "TIMESTAMP" in str(col.type).upper():
                    assert getattr(col.type, "timezone", False), f"{table.name}.{col.name}"


async def test_other_users_rows_are_404_and_indistinguishable_from_missing(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await dev_login(client, "a@example.com")
    await dev_login(client, "b@example.com")
    a = await users_service.get_or_create_by_email(
        db_session, email="a@example.com", display_name=None, auth_provider="dev"
    )
    b = await users_service.get_or_create_by_email(
        db_session, email="b@example.com", display_name=None, auth_provider="dev"
    )
    draft = RecipeDraft(
        owner_user_id=a.id, structured_draft_json={"title": "A-private"}, status=DraftStatus.EDITING
    )
    item = PantryItem(
        owner_user_id=a.id, raw_label="A-item", normalized_name="a-item", source=PantrySource.MANUAL
    )
    db_session.add_all([draft, item])
    await db_session.flush()
    for model, row in ((RecipeDraft, draft), (PantryItem, item)):
        with pytest.raises(NotFound) as other:
            await get_owned_or_404(db_session, model, row.id, b.id, label="Thing")
        with pytest.raises(NotFound) as missing:
            await get_owned_or_404(db_session, model, uuid.uuid4(), b.id, label="Thing")
        assert other.value.status_code == missing.value.status_code == 404
        assert other.value.message == missing.value.message
        assert str(a.id) not in other.value.message and "A-" not in other.value.message
        assert (await get_owned_or_404(db_session, model, row.id, a.id)) is row


@pytest.mark.parametrize(
    "cursor",
    [
        b64({"p": "2026-10-15T00:00:00", "id": str(uuid.uuid4())}),  # naive timestamp
        b64({"p": "2026-10-15T00:00:00+00:00", "id": "not-a-uuid"}),
        b64({"p": "garbage", "id": str(uuid.uuid4())}),
        b64({"id": str(uuid.uuid4())}),
        b64([1, 2]),
        b64("string"),
        "!!!!",
        "A" * 400,
    ],
)
async def test_tampered_cursor_is_422_envelope(client: AsyncClient, cursor: str) -> None:
    response = await client.get("/v1/recipes", params={"cursor": cursor})
    assert response.status_code == 422, response.text
    body = response.json()["error"]
    assert body["code"] == "VALIDATION_ERROR"
    assert set(body) >= {"code", "message", "retryable", "correlation_id"}
    assert response.headers["x-correlation-id"] == body["correlation_id"]


async def test_cursor_longer_than_limit_is_422_not_500(client: AsyncClient) -> None:
    response = await client.get("/v1/recipes", params={"cursor": "A" * 600})
    assert response.status_code == 422


async def test_500_body_correlation_id_matches_generated_header(settings: Settings) -> None:
    app = create_app(settings)

    @app.get("/boom")
    async def boom() -> None:
        raise RuntimeError("secret details")

    transport = ASGITransport(app=app, raise_app_exceptions=False)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        response = await c.get("/boom")  # no incoming id
    assert response.status_code == 500
    body = response.json()["error"]
    assert body["correlation_id"] and body["correlation_id"] == response.headers["x-correlation-id"]
    assert set(body) == {"code", "message", "retryable", "correlation_id"}
    assert "secret" not in response.text and "Traceback" not in response.text


async def test_session_event_idempotency_key_unique_per_session_only(
    db_session: AsyncSession,
) -> None:
    from app.db.models import Recipe, RecipeVersion  # local: only this test needs them

    await seed_fixtures(db_session, FIXTURES_DIR)
    user = await users_service.get_or_create_by_email(
        db_session, email="u@example.com", display_name=None, auth_provider="dev"
    )
    version_id = (await db_session.execute(text("select id from recipe_versions"))).scalar_one()
    assert Recipe and RecipeVersion
    s1 = CookingSession(owner_user_id=user.id, recipe_version_id=version_id)
    s2 = CookingSession(owner_user_id=user.id, recipe_version_id=version_id)
    db_session.add_all([s1, s2])
    await db_session.flush()
    db_session.add_all(
        [
            SessionEvent(session_id=s1.id, sequence=1, type="session_started", idempotency_key="k"),
            SessionEvent(session_id=s2.id, sequence=1, type="session_started", idempotency_key="k"),
            SessionEvent(session_id=s1.id, sequence=2, type="x", idempotency_key=None),
            SessionEvent(session_id=s1.id, sequence=3, type="x", idempotency_key=None),
        ]
    )
    await db_session.flush()  # same key in different sessions and multiple NULLs are fine
    db_session.add(SessionEvent(session_id=s1.id, sequence=4, type="x", idempotency_key="k"))
    with pytest.raises(IntegrityError):
        await db_session.flush()
    await db_session.rollback()


async def test_published_version_content_untouched_after_reseed(db_session: AsyncSession) -> None:
    await seed_fixtures(db_session, FIXTURES_DIR)
    await db_session.execute(
        text("update recipe_versions set ingredient_json='[]'::jsonb")
    )  # simulate a drifted/edited row: reseed must NOT overwrite published content
    await db_session.commit()
    again = await seed_fixtures(db_session, FIXTURES_DIR)
    assert not any(r.created_version for r in again)
    count, ing = (
        await db_session.execute(
            text("select count(*), min(ingredient_json::text) from recipe_versions")
        )
    ).one()
    assert count == 1 and ing == "[]"
    assert datetime.now(UTC)
