"""Fix round 1 item 2: slug allocation never 500s, even if the pre-check misses a row."""

from __future__ import annotations

import pytest
from httpx import AsyncClient

from app.domains.recipes import drafts as draft_service
from tests.conftest import bearer
from tests.integration.test_publish import publish_new


async def test_unique_violation_falls_through_to_next_suffix(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    alice = await bearer(client, "alice@example.com")
    await publish_new(client, alice, title="Race")

    async def blind(*_args: object) -> set[str]:
        return set()  # simulate the stale pre-check a concurrent publisher would see

    monkeypatch.setattr(draft_service, "_taken_slugs", blind)
    second = await publish_new(client, alice, title="Race")
    detail = (await client.get(f"/v1/recipes/{second['recipe_id']}")).json()
    assert detail["slug"] == "race-2"


async def test_gives_up_with_409_after_five_collisions(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    alice = await bearer(client, "alice@example.com")
    await publish_new(client, alice, title="Stuck")

    def always_taken(_base: str, _taken: set[str]):
        while True:
            yield "stuck"

    monkeypatch.setattr(draft_service, "_candidates", always_taken)
    draft = (await client.post("/v1/recipes/drafts", json={"title": "Stuck"}, headers=alice)).json()
    await client.patch(
        f"/v1/recipes/drafts/{draft['id']}",
        json={
            "servings": 1,
            "ingredients": [{"id": "i", "name": "x"}],
            "steps": [{"id": "s", "instruction": "y"}],
        },
        headers=alice,
    )
    response = await client.post(
        f"/v1/recipes/drafts/{draft['id']}/publish", json={}, headers=alice
    )
    assert response.status_code == 409, response.text
    assert response.json()["error"]["code"] == "STATE_CONFLICT"
    # Nothing half-written: the draft is still an open draft and there is one recipe.
    again = (await client.get(f"/v1/recipes/drafts/{draft['id']}", headers=alice)).json()
    assert again["status"] == "draft" and again["recipe_id"] is None
    assert len((await client.get("/v1/me/recipes", headers=alice)).json()["items"]) == 1
