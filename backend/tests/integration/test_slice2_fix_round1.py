"""Brief 004 fix round 1 (items 2-8) through the API."""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession

from app.ai.providers.base import PantryObservation, PantryObservationRequest
from app.ai.providers.mock import MockAIProvider
from app.core.config import Settings
from app.db.models import Ingredient
from app.domains.matching.dictionary import load_dictionary
from app.domains.pantry import observations as obs_module
from app.domains.pantry.observations import RATE_LIMIT_PER_HOUR
from app.main import create_app
from app.scripts.seed import seed_fixtures, seed_ingredients, seed_uuid
from tests.conftest import FIXTURES_DIR, bearer

pytestmark = pytest.mark.usefixtures("ingredients")

TOMATO_STIR_FRY_V1 = seed_uuid("version", "egg-and-tomato-stir-fry:1")


def new(label: str, **kw: object) -> dict[str, object]:
    item: dict[str, object] = {
        "raw_label": label,
        "source": "manual",
        "quantity_is_estimate": False,
    }
    item.update(kw)
    return item


async def add(client: AsyncClient, h: dict[str, str], *items: dict, obs: str | None = None):
    return await client.post(
        "/v1/pantry", json={"items": list(items), "observation_id": obs}, headers=h
    )


async def scan(client: AsyncClient, h: dict[str, str], said: str = "honey"):
    return await client.post(
        "/v1/pantry/observations", json={"mode": "transcript", "transcript": said}, headers=h
    )


async def obs_rows(engine: AsyncEngine) -> list[tuple[str, int]]:
    async with engine.connect() as conn:
        rows = await conn.execute(
            text(
                "SELECT status, jsonb_array_length(candidate_json) FROM pantry_observations "
                "ORDER BY created_at"
            )
        )
        return [(s, n) for s, n in rows]


# --- 2. photo estimates in fit ------------------------------------------------------------


async def test_photo_estimate_is_uncertain_until_the_user_types_an_amount(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await seed_fixtures(db_session, FIXTURES_DIR)
    h = await bearer(client, "a@example.com")
    (tomato,) = (
        await add(
            client,
            h,
            new("tomatoes", source="photo", quantity=5, quantity_is_estimate=True, confidence=0.8),
        )
    ).json()["items"]

    async def tomato_line() -> dict:
        r = await client.post(f"/v1/recipe-versions/{TOMATO_STIR_FRY_V1}/fit", json={}, headers=h)
        return next(i for i in r.json()["items"] if i["ingredient_ref"] == "ing-2")

    first = await tomato_line()
    assert first["status"] == "uncertain"
    assert "estimate from a photo" in first["reason"]

    # "still have it" does not turn an estimate into a verified amount
    confirmed = await client.post(f"/v1/pantry/{tomato['id']}/confirm", json={}, headers=h)
    assert confirmed.json()["quantity_is_estimate"] is True
    assert (await tomato_line())["status"] == "uncertain"

    patched = await client.patch(f"/v1/pantry/{tomato['id']}", json={"quantity": 5}, headers=h)
    assert patched.json()["quantity_is_estimate"] is False
    assert (await tomato_line())["status"] == "available"


# --- 3. TTL purge on pantry reads and writes ------------------------------------------------


@pytest.mark.parametrize("trigger", ["post", "get"])
async def test_expired_rows_are_purged_by_pantry_reads_and_writes(
    client: AsyncClient, engine: AsyncEngine, trigger: str
) -> None:
    h = await bearer(client, "a@example.com")
    await scan(client, h)
    async with engine.begin() as conn:
        await conn.execute(
            text("UPDATE pantry_observations SET expires_at = now() - interval '1 second'")
        )
    if trigger == "post":
        assert (await add(client, h, new("honey"))).status_code == 201
    else:
        assert (await client.get("/v1/pantry", headers=h)).status_code == 200
    assert await obs_rows(engine) == []


# --- 4/5. reservation outside the provider call; provider failures ------------------------


class StubProvider(MockAIProvider):
    def __init__(self, behaviour: list[object], engine: AsyncEngine | None = None) -> None:
        super().__init__(FIXTURES_DIR)
        self.behaviour = behaviour
        self.calls = 0
        self.engine = engine
        self.advisory_locks_during_call: list[int] = []

    async def observe(self, request: PantryObservationRequest) -> PantryObservation:
        self.calls += 1
        if self.engine is not None:
            async with self.engine.connect() as conn:
                n = await conn.scalar(
                    text("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory'")
                )
                self.advisory_locks_during_call.append(int(n or 0))
        step = self.behaviour[min(self.calls, len(self.behaviour)) - 1]
        if isinstance(step, BaseException):
            raise step
        if step == "sleep":
            await asyncio.sleep(5)
        if step == "malformed":
            # A model that ignores the schema: wrong types where the contract wants numbers.
            return PantryObservation.model_construct(
                mode="transcript",
                candidates=[{"raw_label": "honey", "confidence": "very"}],  # type: ignore[list-item]
            )
        return await super().observe(request)


@pytest.fixture
async def app_client(
    settings: Settings, clean_tables: None
) -> AsyncIterator[tuple[FastAPI, AsyncClient]]:
    app = create_app(settings)
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as c:
            yield app, c


async def test_no_advisory_lock_is_held_during_the_provider_call(
    app_client: tuple[FastAPI, AsyncClient], engine: AsyncEngine
) -> None:
    app, client = app_client
    stub = StubProvider(["ok"], engine)
    app.state.ai_provider = stub
    h = await bearer(client, "a@example.com")
    assert (await scan(client, h)).status_code == 201
    assert stub.advisory_locks_during_call == [0]
    assert await obs_rows(engine) == [("pending", 1)]


async def test_provider_exception_is_503_and_still_counts(
    app_client: tuple[FastAPI, AsyncClient], engine: AsyncEngine
) -> None:
    app, client = app_client
    app.state.ai_provider = StubProvider([RuntimeError("upstream 500")])
    h = await bearer(client, "a@example.com")
    r = await scan(client, h)
    assert r.status_code == 503
    assert r.json()["error"]["code"] == "PROVIDER_UNAVAILABLE"
    assert r.json()["error"]["retryable"] is True
    assert "upstream" not in r.text
    assert await obs_rows(engine) == [("failed", 0)]
    # failed attempts count toward the hourly limit
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO pantry_observations (id, owner_user_id, mode, provider, "
                "candidate_json, unknowns_json, status, expires_at) "
                "SELECT gen_random_uuid(), owner_user_id, mode, provider, '[]', '[]', 'failed', "
                "expires_at FROM pantry_observations, generate_series(1, :n)"
            ),
            {"n": RATE_LIMIT_PER_HOUR - 1},
        )
    assert (await scan(client, h)).status_code == 429


async def test_provider_timeout_is_503(
    app_client: tuple[FastAPI, AsyncClient], monkeypatch: pytest.MonkeyPatch
) -> None:
    app, client = app_client
    monkeypatch.setattr(obs_module, "PROVIDER_TIMEOUT_SECONDS", 0.05)
    app.state.ai_provider = StubProvider(["sleep"])
    h = await bearer(client, "a@example.com")
    r = await scan(client, h)
    assert r.status_code == 503 and r.json()["error"]["code"] == "PROVIDER_UNAVAILABLE"


async def test_malformed_twice_is_502_and_once_is_retried(
    app_client: tuple[FastAPI, AsyncClient], engine: AsyncEngine
) -> None:
    app, client = app_client
    h = await bearer(client, "a@example.com")
    twice = StubProvider(["malformed", "malformed"])
    app.state.ai_provider = twice
    r = await scan(client, h)
    assert r.status_code == 502 and r.json()["error"]["code"] == "AI_OUTPUT_INVALID"
    assert twice.calls == 2
    once = StubProvider(["malformed", "ok"])
    app.state.ai_provider = once
    r = await scan(client, h)
    assert r.status_code == 201 and once.calls == 2
    assert [c["canonical_name"] for c in r.json()["candidates"]] == ["honey"]
    assert sorted(await obs_rows(engine)) == [("failed", 0), ("pending", 1)]


async def test_failed_and_reserved_rows_cannot_be_linked(
    app_client: tuple[FastAPI, AsyncClient], engine: AsyncEngine
) -> None:
    app, client = app_client
    app.state.ai_provider = StubProvider([RuntimeError("x")])
    h = await bearer(client, "a@example.com")
    await scan(client, h)
    async with engine.connect() as conn:
        obs_id = str(await conn.scalar(text("SELECT id FROM pantry_observations")))
    r = await add(client, h, new("honey", source="voice"), obs=obs_id)
    assert r.status_code == 404
    async with engine.begin() as conn:
        await conn.execute(text("UPDATE pantry_observations SET status = 'pending_provider'"))
    assert (await add(client, h, new("honey", source="voice"), obs=obs_id)).status_code == 404


# --- 7. request rules -----------------------------------------------------------------------


async def test_two_items_merging_into_the_same_row_is_422(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    (eggs,) = (await add(client, h, new("eggs", quantity=2))).json()["items"]
    r = await add(
        client,
        h,
        new("egg", quantity=6, resolution={"merge_into": eggs["id"]}),
        new("eggs", quantity=12, resolution={"merge_into": eggs["id"]}),
    )
    assert r.status_code == 422
    assert r.json()["error"]["fields"] == ["items.1.resolution.merge_into"]
    items = (await client.get("/v1/pantry", headers=h)).json()["items"]
    assert [i["quantity"] for i in items] == [2.0]


async def test_relinking_a_confirmed_observation_is_409_with_no_write(
    client: AsyncClient,
) -> None:
    h = await bearer(client, "a@example.com")
    obs = (await scan(client, h, "honey and eggs")).json()["observation_id"]
    assert (await add(client, h, new("honey", source="voice"), obs=obs)).status_code == 201
    r = await add(client, h, new("eggs", source="voice"), obs=obs)
    assert r.status_code == 409
    assert r.json()["error"] | {"correlation_id": None} == {
        "code": "STATE_CONFLICT",
        "message": "These items were already added",
        "retryable": False,
        "correlation_id": None,
    }
    names = [
        i["normalized_name"] for i in (await client.get("/v1/pantry", headers=h)).json()["items"]
    ]
    assert names == ["honey"]


async def test_zero_quantity_is_422_on_post_and_patch(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    assert (await add(client, h, new("honey", quantity=0, unit="cup"))).status_code == 422
    (honey,) = (await add(client, h, new("honey", quantity=1, unit="cup"))).json()["items"]
    r = await client.patch(f"/v1/pantry/{honey['id']}", json={"quantity": 0}, headers=h)
    assert r.status_code == 422
    r = await client.patch(f"/v1/pantry/{honey['id']}", json={"quantity": None}, headers=h)
    assert r.status_code == 200 and r.json()["quantity"] is None


# --- 8. merge provenance ------------------------------------------------------------------


async def test_merge_without_quantity_keeps_amount_and_its_provenance(
    client: AsyncClient,
) -> None:
    h = await bearer(client, "a@example.com")
    (onion,) = (
        await add(
            client,
            h,
            new("onions", source="photo", quantity=3, quantity_is_estimate=True, confidence=0.8),
        )
    ).json()["items"]
    merged = (
        await add(
            client,
            h,
            new(
                "onion",
                source="manual",
                storage_location="counter",
                resolution={"merge_into": onion["id"]},
            ),
        )
    ).json()["items"][0]
    assert (merged["quantity"], merged["source"], merged["confidence"]) == (3.0, "photo", 0.8)
    assert merged["quantity_is_estimate"] is True
    assert merged["storage_location"] == "counter"
    assert merged["last_confirmed_at"] > onion["last_confirmed_at"]

    merged = (
        await add(
            client,
            h,
            new(
                "onion",
                source="voice",
                confidence=0.9,
                quantity=5,
                unit="count",
                resolution={"merge_into": onion["id"]},
            ),
        )
    ).json()["items"][0]
    assert (merged["quantity"], merged["source"], merged["confidence"]) == (5.0, "voice", 0.9)
    assert merged["quantity_is_estimate"] is False


# --- 6. dictionary: deterministic load, stale rows removed ---------------------------------


async def test_seed_removes_stale_rows_so_old_aliases_cannot_collide(
    db_session: AsyncSession,
) -> None:
    db_session.add(Ingredient(canonical_name="old onion", aliases_json=["green onion"]))
    db_session.add(Ingredient(canonical_name="aaa first", aliases_json=["honey"]))
    await db_session.commit()
    # Before re-seeding, the lenient runtime load is deterministic: first by canonical name wins.
    d = await load_dictionary(db_session)
    assert d.lookup("honey").canonical_name == "aaa first"  # type: ignore[union-attr]
    result = await seed_ingredients(db_session, FIXTURES_DIR)
    await db_session.commit()
    assert result.removed == 2
    names = set((await db_session.execute(select(Ingredient.canonical_name))).scalars())
    assert "old onion" not in names and "aaa first" not in names
    d = await load_dictionary(db_session)
    assert d.lookup("green onion").canonical_name == "scallion"  # type: ignore[union-attr]
    assert d.lookup("honey").canonical_name == "honey"  # type: ignore[union-attr]


async def test_reseeding_keeps_pantry_items_of_removed_entries(
    client: AsyncClient, db_session: AsyncSession, engine: AsyncEngine
) -> None:
    db_session.add(Ingredient(canonical_name="retired thing", aliases_json=[]))
    await db_session.commit()
    h = await bearer(client, "a@example.com")
    (item,) = (await add(client, h, new("retired thing"))).json()["items"]
    assert item["ingredient_id"] is not None
    await seed_ingredients(db_session, FIXTURES_DIR)
    await db_session.commit()
    items = (await client.get("/v1/pantry", headers=h)).json()["items"]
    assert items[0]["normalized_name"] == "retired thing" and items[0]["ingredient_id"] is None
