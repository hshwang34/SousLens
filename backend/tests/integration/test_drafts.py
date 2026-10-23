"""REC-03: draft CRUD, ownership (404), PATCH merge semantics, validation problems."""

from __future__ import annotations

import uuid

from httpx import AsyncClient

from tests.conftest import bearer, draft_payload

DRAFT_KEYS = {
    "id",
    "recipe_id",
    "status",
    "title",
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
    "validation",
    "created_at",
    "updated_at",
}


async def test_create_empty_draft_is_201_with_validation_problems(client: AsyncClient) -> None:
    alice = await bearer(client, "alice@example.com")
    response = await client.post("/v1/recipes/drafts", json={}, headers=alice)
    assert response.status_code == 201, response.text
    draft = response.json()
    assert set(draft) == DRAFT_KEYS
    assert draft["status"] == "draft"
    assert draft["recipe_id"] is None
    assert draft["title"] is None and draft["servings"] is None
    assert draft["ingredients"] == [] and draft["steps"] == []
    assert draft["validation"]["publishable"] is False
    fields = [p["field"] for p in draft["validation"]["problems"]]
    assert fields == ["title", "servings", "ingredients", "steps"]
    assert all(p["message"] for p in draft["validation"]["problems"])


async def test_create_with_fields_is_publishable_and_shapes_match_detail(
    client: AsyncClient,
) -> None:
    alice = await bearer(client, "alice@example.com")
    response = await client.post("/v1/recipes/drafts", json=draft_payload(), headers=alice)
    assert response.status_code == 201, response.text
    draft = response.json()
    assert draft["validation"] == {"publishable": True, "problems": []}
    # Ingredient/step objects are materialised with every RecipeDetail key and defaults.
    assert draft["ingredients"][0] == {
        "id": "ing-1",
        "name": "dried noodles",
        "quantity": 200.0,
        "unit": "g",
        "optional": False,
        "preparation": None,
        "notes": None,
    }
    assert draft["steps"][2] == {
        "id": "step-3",
        "order": 2,
        "instruction": "Toss the noodles through the garlic butter and serve.",
        "ingredient_refs": ["ing-1"],
        "estimated_minutes": None,
        "success_cues": ["Every strand is glossy"],
        "warnings": [],
        "creator_note": None,
        "source_clip_id": None,
        "source_start_ms": None,
        "source_end_ms": None,
        "evidence_origin": "creator_authored",
    }
    assert [s["order"] for s in draft["steps"]] == [0, 1, 2]


async def test_create_requires_auth(client: AsyncClient) -> None:
    response = await client.post("/v1/recipes/drafts", json={})
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "UNAUTHORIZED"


async def test_list_is_mine_only_newest_first_with_counts(client: AsyncClient) -> None:
    alice = await bearer(client, "alice@example.com")
    bob = await bearer(client, "bob@example.com")
    first = (await client.post("/v1/recipes/drafts", json={"title": "A1"}, headers=alice)).json()
    second = (
        await client.post("/v1/recipes/drafts", json=draft_payload(title="A2"), headers=alice)
    ).json()
    await client.post("/v1/recipes/drafts", json={"title": "B1"}, headers=bob)

    body = (await client.get("/v1/recipes/drafts", headers=alice)).json()
    assert [d["id"] for d in body["items"]] == [second["id"], first["id"]]
    summary = body["items"][0]
    assert summary["title"] == "A2"
    assert summary["ingredient_count"] == 3 and summary["step_count"] == 3
    assert summary["validation"]["publishable"] is True
    assert "ingredients" not in summary and "steps" not in summary
    assert "creator_notes" not in summary and "dietary_warnings" not in summary

    # Updating the older draft moves it to the top.
    await client.patch(f"/v1/recipes/drafts/{first['id']}", json={"title": "A1b"}, headers=alice)
    body = (await client.get("/v1/recipes/drafts", headers=alice)).json()
    assert [d["id"] for d in body["items"]] == [first["id"], second["id"]]


async def test_other_users_draft_is_404_for_get_patch_delete_publish(client: AsyncClient) -> None:
    alice = await bearer(client, "alice@example.com")
    bob = await bearer(client, "bob@example.com")
    draft = (await client.post("/v1/recipes/drafts", json={"title": "mine"}, headers=alice)).json()
    url = f"/v1/recipes/drafts/{draft['id']}"
    for response in (
        await client.get(url, headers=bob),
        await client.patch(url, json={"title": "x"}, headers=bob),
        await client.delete(url, headers=bob),
        await client.post(f"{url}/publish", json={}, headers=bob),
    ):
        assert response.status_code == 404, response.text
        assert response.json()["error"]["code"] == "NOT_FOUND"
        assert "mine" not in response.text
    # Still intact for the owner.
    assert (await client.get(url, headers=alice)).json()["title"] == "mine"
    assert (
        await client.get(f"/v1/recipes/drafts/{uuid.uuid4()}", headers=alice)
    ).status_code == 404
    assert (await client.get("/v1/recipes/drafts/not-a-uuid", headers=alice)).status_code == 404


async def test_patch_merges_top_level_and_replaces_arrays_whole(client: AsyncClient) -> None:
    alice = await bearer(client, "alice@example.com")
    draft = (await client.post("/v1/recipes/drafts", json=draft_payload(), headers=alice)).json()
    url = f"/v1/recipes/drafts/{draft['id']}"

    patched = (await client.patch(url, json={"title": "Renamed"}, headers=alice)).json()
    assert patched["title"] == "Renamed"
    assert patched["summary"] == "Fast, garlicky, forgiving."  # untouched
    assert len(patched["ingredients"]) == 3 and len(patched["steps"]) == 3  # untouched

    patched = (
        await client.patch(
            url, json={"ingredients": [{"id": "ing-9", "name": "salt"}]}, headers=alice
        )
    ).json()
    assert [i["id"] for i in patched["ingredients"]] == ["ing-9"]  # whole array replaced
    assert len(patched["steps"]) == 3
    # steps now reference ingredients that no longer exist → validation problems, not a 4xx
    fields = [p["field"] for p in patched["validation"]["problems"]]
    assert fields == [
        "steps[0].ingredient_refs",
        "steps[1].ingredient_refs",
        "steps[2].ingredient_refs",
    ]
    assert patched["validation"]["publishable"] is False

    # null clears a scalar; an echoed whole Draft (read-only keys) is tolerated.
    patched = (
        await client.patch(url, json={**patched, "summary": None, "servings": None}, headers=alice)
    ).json()
    assert patched["summary"] is None and patched["servings"] is None
    assert "servings" in [p["field"] for p in patched["validation"]["problems"]]


async def test_patch_rejects_unknown_keys(client: AsyncClient) -> None:
    alice = await bearer(client, "alice@example.com")
    draft = (await client.post("/v1/recipes/drafts", json={}, headers=alice)).json()
    response = await client.patch(
        f"/v1/recipes/drafts/{draft['id']}", json={"ingredient": []}, headers=alice
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"
    response = await client.patch(
        f"/v1/recipes/drafts/{draft['id']}",
        json={"steps": [{"id": "s", "instruction": "x", "auto_advance": True}]},
        headers=alice,
    )
    assert response.status_code == 422


async def test_step_order_is_normalised_from_array_position(client: AsyncClient) -> None:
    alice = await bearer(client, "alice@example.com")
    steps = [
        {"id": "step-b", "order": 7, "instruction": "second"},
        {"id": "step-a", "instruction": "first"},
        {"id": "step-c", "order": 0, "instruction": "third"},
    ]
    draft = (await client.post("/v1/recipes/drafts", json={"steps": steps}, headers=alice)).json()
    assert [(s["id"], s["order"]) for s in draft["steps"]] == [
        ("step-b", 0),
        ("step-a", 1),
        ("step-c", 2),
    ]
    reordered = (
        await client.patch(
            f"/v1/recipes/drafts/{draft['id']}",
            json={"steps": [draft["steps"][2], draft["steps"][0], draft["steps"][1]]},
            headers=alice,
        )
    ).json()
    assert [(s["id"], s["order"]) for s in reordered["steps"]] == [
        ("step-c", 0),
        ("step-b", 1),
        ("step-a", 2),
    ]


async def test_validation_problems_cover_every_publish_rule(client: AsyncClient) -> None:
    alice = await bearer(client, "alice@example.com")
    payload = draft_payload(
        title="   ",
        servings=0,
        ingredients=[
            {"id": "ing-1", "name": "  "},
            {"id": "ing-1", "name": "dup id"},
        ],
        steps=[
            {"id": "step-1", "instruction": "", "ingredient_refs": ["ing-1", "ing-404"]},
            {"id": "step-1", "instruction": "ok"},
        ],
    )
    draft = (await client.post("/v1/recipes/drafts", json=payload, headers=alice)).json()
    problems = {p["field"]: p["message"] for p in draft["validation"]["problems"]}
    assert problems == {
        "title": "Add a title",
        "servings": "Servings must be at least 1",
        "ingredients[0].name": "Ingredient 1 needs a name",
        "ingredients[1].id": "Duplicate ingredient id 'ing-1'",
        "steps[0].instruction": "Step 1 needs an instruction",
        "steps[0].ingredient_refs": "Step 1 references unknown ingredient 'ing-404'",
        "steps[1].id": "Duplicate step id 'step-1'",
    }
    assert draft["validation"]["publishable"] is False


async def test_delete_is_204_then_404(client: AsyncClient) -> None:
    alice = await bearer(client, "alice@example.com")
    draft = (await client.post("/v1/recipes/drafts", json={}, headers=alice)).json()
    url = f"/v1/recipes/drafts/{draft['id']}"
    assert (await client.delete(url, headers=alice)).status_code == 204
    assert (await client.get(url, headers=alice)).status_code == 404
    assert (await client.delete(url, headers=alice)).status_code == 404
    assert (await client.get("/v1/recipes/drafts", headers=alice)).json()["items"] == []


async def test_cover_image_url_must_be_an_absolute_https_url(client: AsyncClient) -> None:
    alice = await bearer(client, "alice@example.com")
    draft = (await client.post("/v1/recipes/drafts", json={}, headers=alice)).json()
    url = f"/v1/recipes/drafts/{draft['id']}"
    ok = "https://images.example.com/covers/noodles.jpg?w=1200"
    patched = await client.patch(url, json={"cover_image_url": ok}, headers=alice)
    assert patched.status_code == 200, patched.text
    assert patched.json()["cover_image_url"] == ok
    cleared = await client.patch(url, json={"cover_image_url": None}, headers=alice)
    assert cleared.json()["cover_image_url"] is None

    for bad in (
        "http://images.example.com/cover.jpg",
        "javascript:alert(1)",
        "file:///etc/passwd",
        "/covers/relative.jpg",
        "images.example.com/cover.jpg",
        "https://",
        "https://user:pass@images.example.com/cover.jpg",
        "https://images.example.com/" + "a" * 2048,
    ):
        response = await client.patch(url, json={"cover_image_url": bad}, headers=alice)
        assert response.status_code == 422, bad
        error = response.json()["error"]
        assert error["code"] == "VALIDATION_ERROR"
        assert error["fields"] == ["body.cover_image_url"], bad
        assert bad not in response.text  # values are never echoed
    created = await client.post(
        "/v1/recipes/drafts", json={"cover_image_url": "http://x.example"}, headers=alice
    )
    assert created.status_code == 422
    assert (await client.get(url, headers=alice)).json()["cover_image_url"] is None


async def _new_draft(client: AsyncClient) -> tuple[dict[str, str], str]:
    alice = await bearer(client, "alice@example.com")
    draft = (await client.post("/v1/recipes/drafts", json={}, headers=alice)).json()
    return alice, f"/v1/recipes/drafts/{draft['id']}"


async def test_nul_in_title_is_422_not_500(client: AsyncClient) -> None:
    alice, url = await _new_draft(client)
    for method, path in (("patch", url), ("post", "/v1/recipes/drafts")):
        response = await client.request(method, path, json={"title": "Soup\u0000"}, headers=alice)
        assert response.status_code == 422, response.text
        assert response.json()["error"]["code"] == "VALIDATION_ERROR"
        assert response.json()["error"]["fields"] == ["body.title"]


async def test_control_and_bidi_characters_are_rejected_in_every_text_field(
    client: AsyncClient,
) -> None:
    alice, url = await _new_draft(client)
    ing = {"id": "ing-1", "name": "salt"}
    step = {"id": "step-1", "instruction": "Stir."}
    cases = {
        "body.title": {"title": "a\u202eb"},
        "body.summary": {"summary": "a\u0007b"},
        "body.tags.0": {"tags": ["a\u2066b"]},
        "body.creator_notes.0": {"creator_notes": ["a\u007fb"]},
        "body.dietary_warnings.0": {"dietary_warnings": ["a\u001bb"]},
        "body.ingredients.0.id": {"ingredients": [{**ing, "id": "i\u0000"}]},
        "body.ingredients.0.name": {"ingredients": [{**ing, "name": "sa\u202alt"}]},
        "body.ingredients.0.unit": {"ingredients": [{**ing, "unit": "g\u000b"}]},
        "body.ingredients.0.preparation": {"ingredients": [{**ing, "preparation": "\u000c"}]},
        "body.ingredients.0.notes": {"ingredients": [{**ing, "notes": "\u0001"}]},
        "body.steps.0.instruction": {"steps": [{**step, "instruction": "x\u2069"}]},
        "body.steps.0.ingredient_refs.0": {"steps": [{**step, "ingredient_refs": ["\u0002"]}]},
        "body.steps.0.success_cues.0": {"steps": [{**step, "success_cues": ["\u202d"]}]},
        "body.steps.0.warnings.0": {"steps": [{**step, "warnings": ["\u0010"]}]},
        "body.steps.0.creator_note": {"steps": [{**step, "creator_note": "\u0000"}]},
    }
    for field, body in cases.items():
        response = await client.patch(url, json=body, headers=alice)
        assert response.status_code == 422, (field, response.text)
        assert response.json()["error"]["fields"] == [field], field


async def test_newlines_only_in_multiline_fields(client: AsyncClient) -> None:
    alice, url = await _new_draft(client)
    ok = {
        "summary": "line 1\nline 2",
        "creator_notes": ["a\nb"],
        "dietary_warnings": ["a\r\nb"],
        "ingredients": [{"id": "ing-1", "name": "salt", "notes": "a\nb"}],
        "steps": [
            {
                "id": "step-1",
                "instruction": "Stir.\nThen taste.",
                "success_cues": ["a\nb"],
                "warnings": ["a\nb"],
                "creator_note": "a\nb",
            }
        ],
    }
    response = await client.patch(url, json=ok, headers=alice)
    assert response.status_code == 200, response.text
    assert response.json()["steps"][0]["instruction"] == "Stir.\nThen taste."
    single = {
        "body.title": {"title": "a\nb"},
        "body.tags.0": {"tags": ["a\nb"]},
        "body.ingredients.0.name": {"ingredients": [{"id": "i", "name": "a\nb"}]},
        "body.ingredients.0.unit": {"ingredients": [{"id": "i", "unit": "a\rb"}]},
        "body.ingredients.0.preparation": {"ingredients": [{"id": "i", "preparation": "a\nb"}]},
        "body.steps.0.id": {"steps": [{"id": "s\n", "instruction": "x"}]},
    }
    for field, body in single.items():
        response = await client.patch(url, json=body, headers=alice)
        assert response.status_code == 422, (field, response.text)
        assert response.json()["error"]["fields"] == [field], field


async def test_text_length_limits_and_trimming(client: AsyncClient) -> None:
    alice, url = await _new_draft(client)
    body = await client.patch(
        url, json={"title": "  Soup  ", "tags": ["  Weeknight ", "KOREAN"]}, headers=alice
    )
    assert body.status_code == 200
    assert body.json()["title"] == "Soup" and body.json()["tags"] == ["weeknight", "korean"]
    at_limit = {
        "title": " " + "t" * 120 + " ",
        "summary": "s" * 1000,
        "tags": ["g" * 40],
        "creator_notes": ["n" * 500],
        "ingredients": [
            {"id": "i" * 64, "name": "n" * 200, "unit": "u" * 32, "preparation": "p" * 200,
             "notes": "o" * 500}
        ],
        "steps": [
            {"id": "s", "instruction": "x" * 2000, "ingredient_refs": ["i" * 64],
             "success_cues": ["c" * 500], "warnings": ["w" * 500], "creator_note": "c" * 500}
        ],
    }  # fmt: skip
    assert (await client.patch(url, json=at_limit, headers=alice)).status_code == 200
    ing = {"id": "ing-1", "name": "salt"}
    step = {"id": "step-1", "instruction": "Stir."}
    over = {
        "body.title": {"title": "t" * 121},
        "body.summary": {"summary": "s" * 1001},
        "body.tags.0": {"tags": ["g" * 41]},
        "body.tags.1": {"tags": ["ok", "   "]},
        "body.creator_notes.0": {"creator_notes": ["n" * 501]},
        "body.dietary_warnings.0": {"dietary_warnings": ["n" * 501]},
        "body.ingredients.0.id": {"ingredients": [{**ing, "id": "i" * 65}]},
        "body.ingredients.0.name": {"ingredients": [{**ing, "name": "n" * 201}]},
        "body.ingredients.0.unit": {"ingredients": [{**ing, "unit": "u" * 33}]},
        "body.ingredients.0.preparation": {"ingredients": [{**ing, "preparation": "p" * 201}]},
        "body.ingredients.0.notes": {"ingredients": [{**ing, "notes": "o" * 501}]},
        "body.steps.0.instruction": {"steps": [{**step, "instruction": "x" * 2001}]},
        "body.steps.0.ingredient_refs.0": {"steps": [{**step, "ingredient_refs": ["r" * 65]}]},
        "body.steps.0.success_cues.0": {"steps": [{**step, "success_cues": ["c" * 501]}]},
        "body.steps.0.warnings.0": {"steps": [{**step, "warnings": ["w" * 501]}]},
        "body.steps.0.creator_note": {"steps": [{**step, "creator_note": "c" * 501}]},
    }
    for field, payload in over.items():
        response = await client.patch(url, json=payload, headers=alice)
        assert response.status_code == 422, (field, response.text)
        assert response.json()["error"]["fields"] == [field], field


async def test_null_array_is_422_null_scalar_clears(client: AsyncClient) -> None:
    alice, url = await _new_draft(client)
    await client.patch(url, json={"summary": "x", "tags": ["a"]}, headers=alice)
    cleared = await client.patch(url, json={"summary": None}, headers=alice)
    assert cleared.status_code == 200 and cleared.json()["summary"] is None
    for field in ("tags", "ingredients", "steps", "creator_notes", "dietary_warnings"):
        response = await client.patch(url, json={field: None}, headers=alice)
        assert response.status_code == 422, field
        assert response.json()["error"]["fields"] == [f"body.{field}"], field
