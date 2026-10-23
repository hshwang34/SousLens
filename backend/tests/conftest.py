"""Shared fixtures. Integration tests hit a real Postgres (``TEST_DATABASE_URL``).

The schema is reset and migrated with alembic once per session; every table is truncated before
each test so tests never depend on order.
"""

from __future__ import annotations

import asyncio
import os
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.core.config import Settings
from app.db.base import Base
from app.db.engine import make_engine, make_sessionmaker
from app.main import create_app

BACKEND_DIR = Path(__file__).resolve().parents[1]
FIXTURES_DIR = BACKEND_DIR.parent / "fixtures"
TEST_JWT_SECRET = "test-secret-not-for-production-0123456789"


def _test_database_url() -> str:
    url = (
        os.environ.get("TEST_DATABASE_URL")
        or Settings(jwt_secret=TEST_JWT_SECRET).test_database_url
    )
    db_name = url.rsplit("/", 1)[-1].split("?", 1)[0]
    if not db_name.endswith("_test"):
        raise RuntimeError(
            f"Refusing to run tests against database {db_name!r}: TEST_DATABASE_URL must point at "
            "a database whose name ends with '_test' (the suite drops and recreates its schema)."
        )
    return url


@pytest.fixture(scope="session")
def settings() -> Settings:
    return Settings(
        database_url=_test_database_url(),
        environment="test",
        auth_mode="dev",
        dev_login_echo_code=True,
        dev_login_cooldown_seconds=0,
        ai_provider="mock",
        jwt_secret=TEST_JWT_SECRET,
        log_level="WARNING",
        fixtures_dir=FIXTURES_DIR,
    )


@pytest.fixture(scope="session")
async def migrated_db(settings: Settings) -> None:
    engine = make_engine(settings.database_url)
    async with engine.begin() as conn:
        await conn.execute(text("DROP SCHEMA public CASCADE"))
        await conn.execute(text("CREATE SCHEMA public"))
    await engine.dispose()

    cfg = Config(str(BACKEND_DIR / "alembic.ini"))
    cfg.set_main_option("sqlalchemy.url", settings.database_url)
    # env.py calls asyncio.run(); run it off the test loop.
    await asyncio.to_thread(command.upgrade, cfg, "head")


@pytest.fixture(scope="session")
async def engine(settings: Settings, migrated_db: None) -> AsyncIterator[AsyncEngine]:
    engine = make_engine(settings.database_url)
    yield engine
    await engine.dispose()


@pytest.fixture
async def clean_tables(engine: AsyncEngine) -> None:
    tables = ", ".join(f'"{t.name}"' for t in Base.metadata.sorted_tables)
    async with engine.begin() as conn:
        # recipe_versions is append-only (migration 0002); the test reset uses the operator unlock.
        await conn.execute(text("SET LOCAL souslens.unlock_versions = 'on'"))
        await conn.execute(text(f"TRUNCATE {tables} RESTART IDENTITY CASCADE"))


@pytest.fixture
async def db_session(engine: AsyncEngine, clean_tables: None) -> AsyncIterator[AsyncSession]:
    maker: async_sessionmaker[AsyncSession] = make_sessionmaker(engine)
    async with maker() as session:
        yield session


@pytest.fixture
async def client(settings: Settings, clean_tables: None) -> AsyncIterator[AsyncClient]:
    app = create_app(settings)
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


@pytest.fixture
async def apple_mode_client(settings: Settings, clean_tables: None) -> AsyncIterator[AsyncClient]:
    app = create_app(settings.model_copy(update={"auth_mode": "apple"}))
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


async def start_dev_sign_in(client: AsyncClient, email: str) -> dict[str, str]:
    """Step 1 of dev login. Returns the 202 body (with the echoed code in the test env)."""
    response = await client.post("/v1/auth/dev-login", json={"email": email})
    assert response.status_code == 202, response.text
    return response.json()


async def dev_sign_in(client: AsyncClient, email: str) -> str:
    """Full two-step dev login (challenge → verify with the echoed code) → access token."""
    challenge = await start_dev_sign_in(client, email)
    response = await client.post(
        "/v1/auth/dev-login/verify",
        json={"challenge_id": challenge["challenge_id"], "code": challenge["code"]},
    )
    assert response.status_code == 200, response.text
    return response.json()["access_token"]


dev_login = dev_sign_in  # backwards-compatible name used by earlier gate probes


async def bearer(client: AsyncClient, email: str) -> dict[str, str]:
    """Authorization header for a freshly signed-in dev user."""
    return {"Authorization": f"Bearer {await dev_sign_in(client, email)}"}


def draft_payload(**overrides: object) -> dict[str, object]:
    """A publishable draft (brief 003 rules) that tests tweak via ``overrides``."""
    payload: dict[str, object] = {
        "title": "Weeknight Garlic Noodles",
        "summary": "Fast, garlicky, forgiving.",
        "tags": ["noodles", "weeknight"],
        "servings": 2,
        "prep_minutes": 5,
        "cook_minutes": 10,
        "ingredients": [
            {"id": "ing-1", "name": "dried noodles", "quantity": 200, "unit": "g"},
            {
                "id": "ing-2",
                "name": "garlic",
                "quantity": 4,
                "unit": "clove",
                "preparation": "sliced",
            },
            {"id": "ing-3", "name": "butter", "quantity": 2, "unit": "tbsp", "optional": True},
        ],
        "steps": [
            {
                "id": "step-1",
                "instruction": "Boil the noodles until just tender.",
                "ingredient_refs": ["ing-1"],
                "estimated_minutes": 6,
                "success_cues": ["Noodles bend without snapping"],
            },
            {
                "id": "step-2",
                "instruction": "Toast the garlic in butter over low heat.",
                "ingredient_refs": ["ing-2", "ing-3"],
                "estimated_minutes": 3,
                "success_cues": ["Garlic is pale gold"],
                "warnings": ["Garlic burns fast; keep the heat low."],
                "creator_note": "Low and slow.",
            },
            {
                "id": "step-3",
                "instruction": "Toss the noodles through the garlic butter and serve.",
                "ingredient_refs": ["ing-1"],
                "success_cues": ["Every strand is glossy"],
            },
        ],
        "creator_notes": ["Use the pasta water to loosen the sauce."],
        "dietary_warnings": ["Contains wheat and dairy."],
    }
    payload.update(overrides)
    return payload


@pytest.fixture
async def ingredients(engine: AsyncEngine, clean_tables: None) -> None:
    """Seed ``fixtures/ingredients.json`` (brief 004) so pantry/fit tests get aliases."""
    from app.scripts.seed import seed_ingredients

    async with make_sessionmaker(engine)() as session:
        await seed_ingredients(session, FIXTURES_DIR)
        await session.commit()
