"""REC-02: idempotent save/unsave, ``/me/saved`` order, the ``saved`` flag."""

from __future__ import annotations

import uuid

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from app.scripts.seed import seed_fixtures
from tests.conftest import FIXTURES_DIR, bearer

GOCHUJANG = "gochujang-chicken-thighs"


async def seed(db_session: AsyncSession) -> dict[str, str]:
    return {r.slug: str(r.recipe_id) for r in await seed_fixtures(db_session, FIXTURES_DIR)}


async def test_save_and_unsave_are_idempotent(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    ids = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    url = f"/v1/recipes/{ids[GOCHUJANG]}/save"
    for _ in range(2):
        response = await client.post(url, headers=alice)
        assert response.status_code == 200, response.text
        assert response.json() == {"recipe_id": ids[GOCHUJANG], "saved": True}
    assert len((await client.get("/v1/me/saved", headers=alice)).json()["items"]) == 1
    for _ in range(2):
        response = await client.delete(url, headers=alice)
        assert response.status_code == 200
        assert response.json() == {"recipe_id": ids[GOCHUJANG], "saved": False}
    assert (await client.get("/v1/me/saved", headers=alice)).json()["items"] == []
    # unsaving something never saved (even an unknown id) is still a 200
    response = await client.delete(f"/v1/recipes/{uuid.uuid4()}/save", headers=alice)
    assert response.status_code == 200 and response.json()["saved"] is False


async def test_save_requires_auth_and_a_visible_recipe(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    ids = await seed(db_session)
    assert (await client.post(f"/v1/recipes/{ids[GOCHUJANG]}/save")).status_code == 401
    alice = await bearer(client, "alice@example.com")
    assert (await client.post(f"/v1/recipes/{uuid.uuid4()}/save", headers=alice)).status_code == 404
    assert (await client.post("/v1/recipes/nope/save", headers=alice)).status_code == 404


async def test_me_saved_is_newest_save_first_and_per_user(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    ids = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    bob = await bearer(client, "bob@example.com")
    order = ["cucumber-salad", GOCHUJANG, "garlic-pasta"]
    for slug in order:
        await client.post(f"/v1/recipes/{ids[slug]}/save", headers=alice)
    await client.post(f"/v1/recipes/{ids['kimchi-fried-rice']}/save", headers=bob)

    saved = (await client.get("/v1/me/saved", headers=alice)).json()["items"]
    assert [c["slug"] for c in saved] == list(reversed(order))
    assert all(c["saved"] is True for c in saved)
    assert [c["slug"] for c in (await client.get("/v1/me/saved", headers=bob)).json()["items"]] == [
        "kimchi-fried-rice"
    ]
    assert (await client.get("/v1/me/saved")).status_code == 401


async def test_saved_flag_in_list_and_detail(client: AsyncClient, db_session: AsyncSession) -> None:
    ids = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    bob = await bearer(client, "bob@example.com")
    await client.post(f"/v1/recipes/{ids[GOCHUJANG]}/save", headers=alice)

    anonymous = (await client.get("/v1/recipes")).json()["items"]
    assert {c["saved"] for c in anonymous} == {None}
    assert (await client.get(f"/v1/recipes/{ids[GOCHUJANG]}")).json()["saved"] is None

    as_alice = {
        c["slug"]: c["saved"]
        for c in (await client.get("/v1/recipes", headers=alice)).json()["items"]
    }
    assert as_alice[GOCHUJANG] is True
    assert all(v is False for s, v in as_alice.items() if s != GOCHUJANG)
    assert (await client.get(f"/v1/recipes/{ids[GOCHUJANG]}", headers=alice)).json()[
        "saved"
    ] is True

    as_bob = {
        c["slug"]: c["saved"]
        for c in (await client.get("/v1/recipes", headers=bob)).json()["items"]
    }
    assert set(as_bob.values()) == {False}
    assert (await client.get(f"/v1/recipes/{ids[GOCHUJANG]}", headers=bob)).json()["saved"] is False
    version_id = anonymous[0]["recipe_version_id"]
    assert (await client.get(f"/v1/recipe-versions/{version_id}", headers=alice)).json()[
        "saved"
    ] is True


async def test_presented_but_invalid_token_is_401_on_public_routes(client: AsyncClient) -> None:
    bad = {"Authorization": "Bearer not-a-token"}
    assert (await client.get("/v1/recipes", headers=bad)).status_code == 401
    assert (await client.get(f"/v1/recipes/{uuid.uuid4()}", headers=bad)).status_code == 401
