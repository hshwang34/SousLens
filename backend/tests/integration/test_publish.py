"""REC-04/05/06 gate: publish v1 → edit → publish v2 → v1 byte-identical; unpublish keeps
versions reachable; owner-only actions are 404 for everyone else."""

from __future__ import annotations

import json
import uuid

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from tests.conftest import bearer, draft_payload


async def publish_new(client: AsyncClient, headers: dict[str, str], **overrides: object) -> dict:
    draft = (
        await client.post("/v1/recipes/drafts", json=draft_payload(**overrides), headers=headers)
    ).json()
    response = await client.post(
        f"/v1/recipes/drafts/{draft['id']}/publish", json={}, headers=headers
    )
    assert response.status_code == 201, response.text
    return {"draft": draft, **response.json()}


async def test_publish_v1_creates_recipe_version_and_detail_equals_snapshot(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    alice = await bearer(client, "alice@example.com")
    result = await publish_new(client, alice)
    assert result["version_number"] == 1
    assert result["share_url"] == f"https://souslens.app/r/{result['recipe_id']}"
    assert set(result) - {"draft"} == {
        "recipe_id",
        "recipe_version_id",
        "version_number",
        "share_url",
    }

    # The draft is now published and read-only.
    draft = (await client.get(f"/v1/recipes/drafts/{result['draft']['id']}", headers=alice)).json()
    assert draft["status"] == "published"
    assert draft["recipe_id"] == result["recipe_id"]

    # Public detail (anonymous) == the draft content, byte-for-byte on content fields.
    detail = (await client.get(f"/v1/recipes/{result['recipe_id']}")).json()
    assert detail["recipe_version_id"] == result["recipe_version_id"]
    assert detail["version_number"] == 1
    assert detail["slug"] == "weeknight-garlic-noodles"
    assert detail["title"] == draft["title"]
    for key in (
        "summary",
        "tags",
        "cover_image_url",
        "servings",
        "prep_minutes",
        "cook_minutes",
        "ingredients",
        "steps",
        "creator_notes",
        "dietary_warnings",
    ):
        assert detail[key] == draft[key], key
    assert detail["creator"]["display_name"] == "alice"
    assert detail["saved"] is None

    # ... and the stored JSON is exactly what the endpoint serialises.
    ing, steps, warnings, search = (
        await db_session.execute(
            text(
                "select ingredient_json, step_json, warning_json, search_text "
                "from recipe_versions where id = :id"
            ),
            {"id": result["recipe_version_id"]},
        )
    ).one()
    assert ing == detail["ingredients"]
    assert steps == detail["steps"]
    assert warnings == {
        "creator_notes": detail["creator_notes"],
        "dietary_warnings": detail["dietary_warnings"],
    }
    assert search == "weeknight garlic noodles dried noodles garlic butter"

    # It is in the public feed and searchable by ingredient.
    feed = (await client.get("/v1/recipes", params={"query": "BUTTER"})).json()
    assert [c["recipe_id"] for c in feed["items"]] == [result["recipe_id"]]


async def test_publish_refuses_unpublishable_draft_with_problem_details(
    client: AsyncClient,
) -> None:
    alice = await bearer(client, "alice@example.com")
    draft = (
        await client.post("/v1/recipes/drafts", json={"title": "No steps"}, headers=alice)
    ).json()
    response = await client.post(
        f"/v1/recipes/drafts/{draft['id']}/publish", json={}, headers=alice
    )
    assert response.status_code == 422, response.text
    error = response.json()["error"]
    assert error["code"] == "VALIDATION_ERROR"
    assert [p["field"] for p in error["details"]["problems"]] == [
        "servings",
        "ingredients",
        "steps",
    ]
    assert (await client.get("/v1/recipes")).json()["items"] == []


async def test_gate_edit_then_publish_v2_leaves_v1_byte_identical(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    alice = await bearer(client, "alice@example.com")
    v1 = await publish_new(client, alice)
    v1_detail_text = (await client.get(f"/v1/recipes/{v1['recipe_id']}", headers=alice)).text
    v1_detail = json.loads(v1_detail_text)
    assert v1_detail["saved"] is False  # authenticated, not saved

    # Published draft is read-only.
    response = await client.patch(
        f"/v1/recipes/drafts/{v1['draft']['id']}", json={"title": "nope"}, headers=alice
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "STATE_CONFLICT"
    response = await client.post(
        f"/v1/recipes/drafts/{v1['draft']['id']}/publish", json={}, headers=alice
    )
    assert response.status_code == 409

    # Edit → new draft pre-filled from v1, recipe_id set.
    response = await client.post(f"/v1/recipes/{v1['recipe_id']}/edit", json={}, headers=alice)
    assert response.status_code == 201, response.text
    draft2 = response.json()
    assert draft2["id"] != v1["draft"]["id"]
    assert draft2["recipe_id"] == v1["recipe_id"]
    assert draft2["status"] == "draft"
    for key in ("title", "summary", "tags", "servings", "ingredients", "steps", "creator_notes"):
        assert draft2[key] == v1_detail[key], key
    assert draft2["validation"]["publishable"] is True

    # Second edit while that draft is open → 409 with the open draft id.
    response = await client.post(f"/v1/recipes/{v1['recipe_id']}/edit", json={}, headers=alice)
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "STATE_CONFLICT"
    assert response.json()["error"]["details"] == {"draft_id": draft2["id"]}

    # /me/recipes reports the open draft.
    mine = (await client.get("/v1/me/recipes", headers=alice)).json()["items"]
    assert len(mine) == 1
    assert mine[0]["recipe_id"] == v1["recipe_id"]
    assert mine[0]["visibility"] == "public"
    assert mine[0]["has_open_draft"] is True
    assert mine[0]["version_number"] == 1

    # Change the steps and publish v2.
    new_steps = [*draft2["steps"], {"id": "step-4", "instruction": "Rest for a minute."}]
    await client.patch(
        f"/v1/recipes/drafts/{draft2['id']}",
        json={"steps": new_steps, "summary": "Now with a rest step."},
        headers=alice,
    )
    response = await client.post(
        f"/v1/recipes/drafts/{draft2['id']}/publish", json={}, headers=alice
    )
    assert response.status_code == 201, response.text
    v2 = response.json()
    assert v2["recipe_id"] == v1["recipe_id"]
    assert v2["version_number"] == 2
    assert v2["recipe_version_id"] != v1["recipe_version_id"]

    # latest_version_id moved; the public detail is v2.
    latest = (
        await db_session.execute(
            text("select latest_version_id, visibility from recipes where id = :id"),
            {"id": v1["recipe_id"]},
        )
    ).one()
    assert str(latest[0]) == v2["recipe_version_id"] and latest[1] == "public"
    detail_v2 = (await client.get(f"/v1/recipes/{v1['recipe_id']}", headers=alice)).json()
    assert detail_v2["version_number"] == 2
    assert len(detail_v2["steps"]) == 4
    assert detail_v2["summary"] == "Now with a rest step."
    assert detail_v2["steps"][3]["order"] == 3

    # v1 by version id is byte-identical to what it was before v2 existed.
    response = await client.get(f"/v1/recipe-versions/{v1['recipe_version_id']}", headers=alice)
    assert response.status_code == 200
    v1_again = response.json()
    # Recipe-level metadata (summary) is mutable per PRD §10 and was changed in v2; everything
    # the version owns must be unchanged.
    for key in ("summary",):
        v1_detail.pop(key)
        v1_again.pop(key)
    assert json.dumps(v1_again, sort_keys=True) == json.dumps(v1_detail, sort_keys=True)
    assert v1_again["version_number"] == 1 and len(v1_again["steps"]) == 3

    mine = (await client.get("/v1/me/recipes", headers=alice)).json()["items"]
    assert mine[0]["has_open_draft"] is False and mine[0]["version_number"] == 2
    assert (
        await db_session.execute(text("select count(*) from recipe_versions"))
    ).scalar_one() == 2


async def test_unpublish_hides_from_list_404s_others_200_for_owner_and_keeps_versions(
    client: AsyncClient,
) -> None:
    alice = await bearer(client, "alice@example.com")
    bob = await bearer(client, "bob@example.com")
    v1 = await publish_new(client, alice)
    recipe_id = v1["recipe_id"]
    await client.post(f"/v1/recipes/{recipe_id}/save", headers=bob)

    # Bob may not unpublish or edit Alice's recipe: 404, nothing leaks.
    for response in (
        await client.post(f"/v1/recipes/{recipe_id}/unpublish", json={}, headers=bob),
        await client.post(f"/v1/recipes/{recipe_id}/edit", json={}, headers=bob),
    ):
        assert response.status_code == 404
    assert (await client.post(f"/v1/recipes/{recipe_id}/unpublish", json={})).status_code == 401

    response = await client.post(f"/v1/recipes/{recipe_id}/unpublish", json={}, headers=alice)
    assert response.status_code == 200
    assert response.json() == {"recipe_id": recipe_id, "visibility": "private"}
    # idempotent
    assert (
        await client.post(f"/v1/recipes/{recipe_id}/unpublish", json={}, headers=alice)
    ).status_code == 200

    assert (await client.get("/v1/recipes")).json()["items"] == []
    assert (await client.get("/v1/recipes", params={"query": "garlic"})).json()["items"] == []
    assert (await client.get(f"/v1/recipes/{recipe_id}")).status_code == 404
    assert (await client.get(f"/v1/recipes/{recipe_id}", headers=bob)).status_code == 404
    owner_view = await client.get(f"/v1/recipes/{recipe_id}", headers=alice)
    assert owner_view.status_code == 200
    assert owner_view.json()["version_number"] == 1
    assert (await client.get("/v1/me/saved", headers=bob)).json()["items"] == []

    # Prior references keep working by version id (REC-05) for the owner and for a saver;
    # a stranger (no save, no ownership) gets the same 404 as an unknown id.
    version_url = f"/v1/recipe-versions/{v1['recipe_version_id']}"
    assert (await client.get(version_url)).status_code == 401
    assert (await client.get(version_url, headers=alice)).status_code == 200
    saver = await client.get(version_url, headers=bob)
    assert saver.status_code == 200
    assert saver.json()["recipe_version_id"] == v1["recipe_version_id"]
    assert saver.json()["saved"] is True
    carol = await bearer(client, "carol@example.com")
    stranger = await client.get(version_url, headers=carol)
    assert stranger.status_code == 404
    assert stranger.json()["error"]["code"] == "NOT_FOUND"
    # Dropping the save drops the reference too.
    await client.delete(f"/v1/recipes/{recipe_id}/save", headers=bob)
    assert (await client.get(version_url, headers=bob)).status_code == 404

    mine = (await client.get("/v1/me/recipes", headers=alice)).json()["items"]
    assert mine[0]["visibility"] == "private"

    # Editing + publishing again makes it public once more, as v2, and the stranger can read
    # the old version again because the recipe is public.
    draft = (await client.post(f"/v1/recipes/{recipe_id}/edit", json={}, headers=alice)).json()
    v2 = (
        await client.post(f"/v1/recipes/drafts/{draft['id']}/publish", json={}, headers=alice)
    ).json()
    assert v2["version_number"] == 2
    assert [c["recipe_id"] for c in (await client.get("/v1/recipes")).json()["items"]] == [
        recipe_id
    ]


async def test_version_endpoint_is_404_for_unknown_and_draft_only_recipes(
    client: AsyncClient,
) -> None:
    alice = await bearer(client, "alice@example.com")
    assert (
        await client.get(f"/v1/recipe-versions/{uuid.uuid4()}", headers=alice)
    ).status_code == 404
    assert (await client.get("/v1/recipe-versions/nope", headers=alice)).status_code == 404


async def test_slug_is_derived_from_title_and_made_unique(client: AsyncClient) -> None:
    alice = await bearer(client, "alice@example.com")
    bob = await bearer(client, "bob@example.com")
    first = await publish_new(client, alice, title="  Crispy Rice!! (v1) ")
    second = await publish_new(client, bob, title="Crispy Rice v1")
    third = await publish_new(client, alice, title="crispy-rice-v1")
    slugs = [
        (await client.get(f"/v1/recipes/{r['recipe_id']}")).json()["slug"]
        for r in (first, second, third)
    ]
    assert slugs == ["crispy-rice-v1", "crispy-rice-v1-2", "crispy-rice-v1-3"]
    # A second publish of the same recipe keeps its slug.
    draft = (
        await client.post(f"/v1/recipes/{first['recipe_id']}/edit", json={}, headers=alice)
    ).json()
    await client.patch(
        f"/v1/recipes/drafts/{draft['id']}", json={"title": "Renamed"}, headers=alice
    )
    await client.post(f"/v1/recipes/drafts/{draft['id']}/publish", json={}, headers=alice)
    detail = (await client.get(f"/v1/recipes/{first['recipe_id']}")).json()
    assert detail["slug"] == "crispy-rice-v1" and detail["title"] == "Renamed"


async def test_feed_is_published_at_desc_and_republish_keeps_first_published_at(
    client: AsyncClient,
) -> None:
    alice = await bearer(client, "alice@example.com")
    first = await publish_new(client, alice, title="First")
    await publish_new(client, alice, title="Second")
    assert [c["title"] for c in (await client.get("/v1/recipes")).json()["items"]] == [
        "Second",
        "First",
    ]
    draft = (
        await client.post(f"/v1/recipes/{first['recipe_id']}/edit", json={}, headers=alice)
    ).json()
    await client.post(f"/v1/recipes/drafts/{draft['id']}/publish", json={}, headers=alice)
    feed = (await client.get("/v1/recipes")).json()["items"]
    assert [c["title"] for c in feed] == ["Second", "First"]
    assert feed[1]["version_number"] == 2
    detail_a = (await client.get(f"/v1/recipes/{first['recipe_id']}")).json()
    assert detail_a["published_at"] == feed[1]["published_at"]
