"""POST /recipe-versions/{id}/fit (FIT-01..03) and PRD §17.2 scenarios 3 and 12."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.db.models import Ingredient
from app.scripts.seed import seed_fixtures, seed_ingredients, seed_uuid
from tests.conftest import FIXTURES_DIR, bearer, draft_payload

pytestmark = pytest.mark.usefixtures("ingredients")

GOCHUJANG_V1 = seed_uuid("version", "gochujang-chicken-thighs:1")
KIMCHI_V1 = seed_uuid("version", "kimchi-fried-rice:1")


@pytest.fixture
async def seeded(db_session) -> None:  # type: ignore[no-untyped-def]
    await seed_fixtures(db_session, FIXTURES_DIR)


async def add(client: AsyncClient, h: dict[str, str], *items: dict) -> list[dict]:
    r = await client.post("/v1/pantry", json={"items": list(items)}, headers=h)
    assert r.status_code == 201, r.text
    return r.json()["items"]


def m(label: str, quantity: float | None = None, unit: str | None = None) -> dict:
    return {"raw_label": label, "quantity": quantity, "unit": unit, "source": "manual"}


async def fit(client: AsyncClient, h: dict[str, str], version_id: object) -> dict:
    r = await client.post(f"/v1/recipe-versions/{version_id}/fit", json={}, headers=h)
    assert r.status_code == 200, r.text
    return r.json()


def by_ref(result: dict) -> dict[str, dict]:
    return {i["ingredient_ref"]: i for i in result["items"]}


@pytest.mark.usefixtures("seeded")
async def test_empty_pantry_shape(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    result = await fit(client, h, GOCHUJANG_V1)
    assert set(result) == {
        "recipe_version_id",
        "can_make",
        "coverage",
        "counts",
        "items",
        "computed_at",
    }
    assert result["recipe_version_id"] == str(GOCHUJANG_V1)
    assert result["can_make"] is False and result["coverage"] == 0.0
    assert result["counts"] == {
        "available": 0,
        "uncertain": 0,
        "missing": 10,
        "optional_missing": 2,
    }
    item = result["items"][0]
    assert set(item) == {
        "ingredient_ref",
        "name",
        "optional",
        "status",
        "reason",
        "required",
        "pantry_item_id",
        "pantry_quantity",
        "conversion_note",
    }
    assert item["required"] == {"quantity": 2.0, "unit": "lb"}
    assert item["pantry_item_id"] is None and item["pantry_quantity"] is None
    datetime.fromisoformat(result["computed_at"])


@pytest.mark.usefixtures("seeded")
async def test_body_is_optional_and_strict(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    assert (
        await client.post(f"/v1/recipe-versions/{GOCHUJANG_V1}/fit", headers=h)
    ).status_code == 200
    r = await client.post(f"/v1/recipe-versions/{GOCHUJANG_V1}/fit", json={"x": 1}, headers=h)
    assert r.status_code == 422


@pytest.mark.usefixtures("seeded")
async def test_full_pantry_can_make_gochujang_chicken(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    await add(
        client,
        h,
        m("chicken thighs", 3, "lb"),
        m("gochujang", 1, "cup"),
        m("soy sauce", 500, "ml"),
        m("honey", 0.5, "cup"),
        m("toasted sesame oil", 250, "ml"),
        m("garlic"),
        m("ginger"),
        m("rice wine vinegar", 1, "cup"),
        m("canola oil", 1, "l"),
        m("green onions", 6, "count"),
    )
    # garlic (4 clove) and ginger (1 tbsp) have no recorded amount → uncertain, so not yet.
    result = await fit(client, h, GOCHUJANG_V1)
    items = by_ref(result)
    assert items["ing-6"]["status"] == "uncertain" and items["ing-7"]["status"] == "uncertain"
    assert result["can_make"] is False
    assert result["coverage"] == 0.8
    assert items["ing-10"]["status"] == "available"  # scallion = green onion
    assert items["ing-9"]["status"] == "available"  # neutral oil = canola oil
    assert items["ing-2"]["conversion_note"] == "Converted your 1 cup to 16 tbsp."
    assert items["ing-12"]["status"] == "optional_missing"


@pytest.mark.usefixtures("seeded")
async def test_live_smoke_flow_gochujang_3_tbsp_is_available(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    obs = (
        await client.post(
            "/v1/pantry/observations",
            json={
                "mode": "transcript",
                "transcript": "chicken thighs, two onions, 3 tbsp gochujang and honey",
            },
            headers=h,
        )
    ).json()
    g = next(c for c in obs["candidates"] if c["canonical_name"] == "gochujang")
    await client.post(
        "/v1/pantry",
        json={
            "observation_id": obs["observation_id"],
            "items": [
                {
                    "raw_label": g["raw_label"],
                    "quantity": g["quantity"],
                    "unit": g["unit"],
                    "source": "voice",
                    "confidence": g["confidence"],
                    "quantity_is_estimate": False,
                }
            ],
        },
        headers=h,
    )
    assert by_ref(await fit(client, h, GOCHUJANG_V1))["ing-2"]["status"] == "available"


@pytest.mark.usefixtures("seeded")
async def test_quantity_mismatch_scenario_3(client: AsyncClient) -> None:
    """PRD §17.2 scenario 3: 1 egg for a recipe needing more is not marked available."""
    h = await bearer(client, "a@example.com")
    await add(client, h, m("egg", 1, "count"))
    egg = by_ref(await fit(client, h, KIMCHI_V1))["ing-10"]
    assert egg["status"] == "uncertain"
    assert egg["reason"] == "You have 1 egg; the recipe needs 2."
    assert egg["pantry_quantity"] == {"quantity": 1.0, "unit": "count"}


@pytest.mark.usefixtures("seeded")
async def test_gochugaru_does_not_satisfy_gochujang(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    await add(client, h, m("gochugaru", 1, "cup"), m("rice", 2, "kg"))
    items = by_ref(await fit(client, h, GOCHUJANG_V1))
    assert items["ing-2"]["status"] == "missing"
    # raw rice never satisfies cooked rice
    assert by_ref(await fit(client, h, KIMCHI_V1))["ing-1"]["status"] == "missing"


@pytest.mark.usefixtures("seeded")
async def test_stale_item_is_uncertain(client: AsyncClient, engine: AsyncEngine) -> None:
    h = await bearer(client, "a@example.com")
    (item,) = await add(client, h, m("honey", 1, "cup"))
    assert by_ref(await fit(client, h, GOCHUJANG_V1))["ing-4"]["status"] == "available"
    async with engine.begin() as conn:
        await conn.execute(
            text("UPDATE pantry_items SET last_confirmed_at = now() - interval '20 days'")
        )
    honey = by_ref(await fit(client, h, GOCHUJANG_V1))["ing-4"]
    assert honey["status"] == "uncertain" and "20 days ago" in honey["reason"]
    await client.post(f"/v1/pantry/{item['id']}/confirm", json={}, headers=h)
    assert by_ref(await fit(client, h, GOCHUJANG_V1))["ing-4"]["status"] == "available"


@pytest.mark.usefixtures("seeded")
async def test_candidates_never_count_as_pantry(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    r = await client.post(
        "/v1/pantry/observations",
        json={"mode": "transcript", "transcript": "honey and gochujang"},
        headers=h,
    )
    assert r.status_code == 201
    result = await fit(client, h, GOCHUJANG_V1)
    assert result["counts"]["available"] == 0


async def test_fit_uses_only_the_callers_pantry_and_version_access_scenario_12(
    client: AsyncClient,
) -> None:
    """PRD §17.2 scenario 12: a non-owner can't reach another user's pantry or an unpublished
    recipe version through a guessed id, and fit never reads anyone else's pantry."""
    alice = await bearer(client, "alice@example.com")
    bob = await bearer(client, "bob@example.com")
    draft = (await client.post("/v1/recipes/drafts", json=draft_payload(), headers=alice)).json()
    pub = (await client.post(f"/v1/recipes/drafts/{draft['id']}/publish", headers=alice)).json()
    version_id = pub["recipe_version_id"]
    await add(client, alice, m("dried noodles", 1, "kg"), m("garlic"))

    bob_view = await fit(client, bob, version_id)  # public: bob may fit it…
    assert bob_view["counts"]["available"] == 0  # …but only against his own (empty) pantry
    assert bob_view["counts"]["missing"] == 2

    assert (
        await client.post(f"/v1/recipes/{pub['recipe_id']}/unpublish", headers=alice)
    ).status_code == 200
    for vid in (version_id, str(uuid.uuid4()), "not-a-uuid"):
        r = await client.post(f"/v1/recipe-versions/{vid}/fit", json={}, headers=bob)
        assert r.status_code == 404, vid
        assert r.json()["error"]["message"] == "Recipe version not found"
    assert (await fit(client, alice, version_id))["counts"]["available"] == 1


async def test_saved_unpublished_version_is_still_fittable(client: AsyncClient) -> None:
    alice = await bearer(client, "alice@example.com")
    bob = await bearer(client, "bob@example.com")
    draft = (await client.post("/v1/recipes/drafts", json=draft_payload(), headers=alice)).json()
    pub = (await client.post(f"/v1/recipes/drafts/{draft['id']}/publish", headers=alice)).json()
    await client.post(f"/v1/recipes/{pub['recipe_id']}/save", headers=bob)
    await client.post(f"/v1/recipes/{pub['recipe_id']}/unpublish", headers=alice)
    assert (
        await client.post(f"/v1/recipe-versions/{pub['recipe_version_id']}/fit", headers=bob)
    ).status_code == 200


async def test_requires_auth(client: AsyncClient) -> None:
    r = await client.post(f"/v1/recipe-versions/{GOCHUJANG_V1}/fit", json={})
    assert r.status_code == 401


async def test_ingredient_seed_is_idempotent(db_session) -> None:  # type: ignore[no-untyped-def]
    again = await seed_ingredients(db_session, FIXTURES_DIR)  # `ingredients` fixture ran once
    assert (again.created, again.updated) == (0, 0)
    assert again.unchanged >= 80
    row = await db_session.get(Ingredient, seed_uuid("ingredient", "scallion"))
    assert row is not None and "green onion" in row.aliases_json
    assert row.qualifiers == ["fresh", "raw"]
    assert datetime.now(UTC) >= row.updated_at
