"""REC-01/02: public feed, canonical detail and search over the five seeded fixtures."""

from __future__ import annotations

import json
import uuid
from datetime import UTC, datetime, timedelta

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import Recipe, RecipeVersion, Visibility
from app.domains.users import service as users_service
from app.scripts.seed import SEED_CREATOR_EMAIL, seed_fixtures
from tests.conftest import FIXTURES_DIR

GOCHUJANG = "gochujang-chicken-thighs"
SEED_SLUGS_NEWEST_FIRST = [
    GOCHUJANG,
    "kimchi-fried-rice",
    "garlic-pasta",
    "egg-and-tomato-stir-fry",
    "cucumber-salad",
]
EXPECTED_DETAIL = FIXTURES_DIR / "expected_outputs" / "recipe_detail.json"
EXPECTED_LIST = FIXTURES_DIR / "expected_outputs" / "recipes_list.json"
CARD_KEYS = {
    "recipe_id",
    "slug",
    "title",
    "summary",
    "tags",
    "creator",
    "servings",
    "prep_minutes",
    "cook_minutes",
    "cover_image_url",
    "published_at",
    "recipe_version_id",
    "version_number",
    "saved",
}


async def seed(db_session: AsyncSession) -> dict[str, uuid.UUID]:
    results = await seed_fixtures(db_session, FIXTURES_DIR)
    return {r.slug: r.recipe_id for r in results}


async def add_recipe(
    db_session: AsyncSession,
    *,
    slug: str,
    title: str,
    tags: list[str] | None = None,
    visibility: Visibility = Visibility.PUBLIC,
    published: bool = True,
    published_at: datetime | None = None,
) -> Recipe:
    owner = await users_service.get_or_create_by_email(
        db_session, email=SEED_CREATOR_EMAIL, display_name="SousLens Kitchen", auth_provider="dev"
    )
    recipe = Recipe(
        owner_user_id=owner.id, slug=slug, visibility=visibility, title=title, tags=tags or []
    )
    db_session.add(recipe)
    await db_session.flush()
    version = RecipeVersion(
        recipe_id=recipe.id,
        version_number=1,
        servings=2,
        ingredient_json=[],
        step_json=[],
        warning_json={},
        search_text=title.lower(),
    )
    db_session.add(version)
    await db_session.flush()
    recipe.latest_version_id = version.id
    if published:
        recipe.published_at = published_at or datetime.now(UTC)
    await db_session.commit()
    return recipe


def slugs(response) -> list[str]:
    return [c["slug"] for c in response.json()["items"]]


async def test_list_returns_five_seeded_cards_newest_first(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    ids = await seed(db_session)
    response = await client.get("/v1/recipes")
    assert response.status_code == 200
    body = response.json()
    assert body["next_cursor"] is None
    assert slugs(response) == SEED_SLUGS_NEWEST_FIRST
    card = body["items"][0]
    assert card["recipe_id"] == str(ids[GOCHUJANG])
    assert card["title"] == "Gochujang Chicken Thighs"
    assert card["creator"]["display_name"] == "SousLens Kitchen"
    assert card["version_number"] == 1
    assert card["tags"] == ["korean", "chicken", "weeknight", "spicy"]
    assert card["saved"] is None  # anonymous
    assert set(card) == CARD_KEYS


async def test_list_matches_expected_output_fixture_exactly(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await seed(db_session)
    body = (await client.get("/v1/recipes")).json()
    assert body == json.loads(EXPECTED_LIST.read_text(encoding="utf-8"))


async def test_detail_matches_expected_output_fixture_exactly(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    ids = await seed(db_session)
    response = await client.get(f"/v1/recipes/{ids[GOCHUJANG]}")
    assert response.status_code == 200
    body = response.json()
    expected = json.loads(EXPECTED_DETAIL.read_text(encoding="utf-8"))
    assert body == expected

    assert body["schema_version"] == "1.0"
    assert body["saved"] is None
    assert body["share_url"] == f"https://souslens.app/r/{ids[GOCHUJANG]}"
    assert len(body["steps"]) >= 6
    assert any(s["creator_note"] for s in body["steps"])
    assert any("thermometer" in w.lower() for s in body["steps"] for w in s["warnings"])
    assert all(s["success_cues"] for s in body["steps"])
    assert body["creator_notes"] and body["dietary_warnings"]
    ingredient_ids = {i["id"] for i in body["ingredients"]}
    assert all(ref in ingredient_ids for s in body["steps"] for ref in s["ingredient_refs"])


async def test_every_seeded_recipe_meets_appendix_b(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    ids = await seed(db_session)
    assert len(ids) == 5
    for slug, recipe_id in ids.items():
        body = (await client.get(f"/v1/recipes/{recipe_id}")).json()
        assert body["slug"] == slug
        assert len(body["steps"]) >= 5, slug
        assert all(s["success_cues"] for s in body["steps"]), slug
        assert body["creator_notes"], slug
        assert body["tags"], slug
        assert [s["order"] for s in body["steps"]] == list(range(len(body["steps"]))), slug
        ingredient_ids = {i["id"] for i in body["ingredients"]}
        assert all(r in ingredient_ids for s in body["steps"] for r in s["ingredient_refs"]), slug


async def test_detail_requires_no_auth_but_is_404_for_unknown(client: AsyncClient) -> None:
    response = await client.get(f"/v1/recipes/{uuid.uuid4()}")
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "NOT_FOUND"
    assert (await client.get("/v1/recipes/not-a-uuid")).status_code == 404


async def test_seed_is_idempotent_and_never_rewrites_published_version(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    first = await seed_fixtures(db_session, FIXTURES_DIR)
    second = await seed_fixtures(db_session, FIXTURES_DIR)
    assert len(first) == 5
    assert [r.recipe_id for r in first] == [r.recipe_id for r in second]
    assert [r.version_id for r in first] == [r.version_id for r in second]
    assert all(r.created_recipe and r.created_version for r in first)
    assert not any(r.created_recipe or r.created_version for r in second)
    assert len((await client.get("/v1/recipes")).json()["items"]) == 5
    count = (await db_session.execute(text("select count(*) from recipe_versions"))).scalar_one()
    assert count == 5


async def test_query_matches_title_case_insensitively(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await seed(db_session)
    assert slugs(await client.get("/v1/recipes", params={"query": "GOCHUJANG CHICKEN"})) == [
        GOCHUJANG
    ]
    assert slugs(await client.get("/v1/recipes", params={"query": "zzz"})) == []
    assert slugs(await client.get("/v1/recipes", params={"query": "%"})) == []
    assert slugs(await client.get("/v1/recipes", params={"query": "   "})) == (
        SEED_SLUGS_NEWEST_FIRST
    )


async def test_query_matches_any_ingredient_name(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await seed(db_session)
    # gochujang is an ingredient of the chicken (title) and of the fried rice (optional).
    assert slugs(await client.get("/v1/recipes", params={"query": "Gochujang"})) == [
        GOCHUJANG,
        "kimchi-fried-rice",
    ]
    assert slugs(await client.get("/v1/recipes", params={"query": "CUCUMBER"})) == [
        "cucumber-salad"
    ]
    assert slugs(await client.get("/v1/recipes", params={"query": "spaghetti"})) == ["garlic-pasta"]
    # scallion is an ingredient, never a title, in three recipes
    assert slugs(await client.get("/v1/recipes", params={"query": "scallion"})) == [
        GOCHUJANG,
        "kimchi-fried-rice",
        "egg-and-tomato-stir-fry",
    ]


async def test_tag_filter(client: AsyncClient, db_session: AsyncSession) -> None:
    await seed(db_session)
    response = await client.get("/v1/recipes", params={"tag": "korean"})
    assert slugs(response) == [GOCHUJANG, "kimchi-fried-rice"]
    assert slugs(await client.get("/v1/recipes", params={"tag": "no-cook"})) == ["cucumber-salad"]


async def test_cursor_pagination_walks_every_page_once(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await seed(db_session)
    base = datetime(2026, 10, 16, tzinfo=UTC)
    for i in range(3):
        await add_recipe(
            db_session,
            slug=f"extra-{i}",
            title=f"Extra {i}",
            published_at=base + timedelta(hours=i),
        )
    seen: list[str] = []
    cursor: str | None = None
    for _ in range(20):
        params: dict[str, str | int] = {"limit": 2}
        if cursor:
            params["cursor"] = cursor
        page = (await client.get("/v1/recipes", params=params)).json()
        assert 1 <= len(page["items"]) <= 2
        seen.extend(c["slug"] for c in page["items"])
        cursor = page["next_cursor"]
        if cursor is None:
            break
    assert seen == ["extra-2", "extra-1", "extra-0", *SEED_SLUGS_NEWEST_FIRST]


async def test_pagination_tie_breaks_on_id_for_equal_published_at(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    same = datetime(2026, 10, 17, tzinfo=UTC)
    for i in range(3):
        await add_recipe(db_session, slug=f"tie-{i}", title=f"Tie {i}", published_at=same)
    first = (await client.get("/v1/recipes", params={"limit": 2})).json()
    second = (
        await client.get("/v1/recipes", params={"limit": 2, "cursor": first["next_cursor"]})
    ).json()
    found = [c["slug"] for c in first["items"] + second["items"]]
    assert sorted(found) == ["tie-0", "tie-1", "tie-2"]
    assert len(set(found)) == 3
    assert second["next_cursor"] is None


async def test_bad_cursor_is_validation_error(client: AsyncClient) -> None:
    response = await client.get("/v1/recipes", params={"cursor": "garbage"})
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"


async def test_unpublished_and_private_recipes_are_hidden(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await seed(db_session)
    draft = await add_recipe(db_session, slug="draft-only", title="Draft", published=False)
    private = await add_recipe(
        db_session, slug="private-one", title="Private", visibility=Visibility.PRIVATE
    )
    unlisted = await add_recipe(
        db_session, slug="unlisted-one", title="Unlisted", visibility=Visibility.UNLISTED
    )
    assert slugs(await client.get("/v1/recipes")) == SEED_SLUGS_NEWEST_FIRST
    for hidden in (draft, private, unlisted):
        response = await client.get(f"/v1/recipes/{hidden.id}")
        assert response.status_code == 404
        assert response.json()["error"]["code"] == "NOT_FOUND"


PRD_10_1_TOP_LEVEL = {
    "schema_version",
    "recipe_id",
    "recipe_version_id",
    "title",
    "creator_id",
    "servings",
    "prep_minutes",
    "cook_minutes",
    "ingredients",
    "steps",
    "dietary_warnings",
    "published_at",
}
PRD_10_1_INGREDIENT = {"id", "name", "quantity", "unit", "optional", "preparation"}
PRD_10_1_STEP = {
    "id",
    "order",
    "instruction",
    "ingredient_refs",
    "estimated_minutes",
    "success_cues",
    "warnings",
    "source_clip_id",
    "source_start_ms",
    "source_end_ms",
    "evidence_origin",
}


async def test_detail_contains_prd_10_1_keys(client: AsyncClient, db_session: AsyncSession) -> None:
    ids = await seed(db_session)
    body = (await client.get(f"/v1/recipes/{ids[GOCHUJANG]}")).json()
    assert PRD_10_1_TOP_LEVEL <= set(body)
    assert body["creator_id"] == body["creator"]["id"]
    uuid.UUID(body["creator_id"])
    for ingredient in body["ingredients"]:
        assert PRD_10_1_INGREDIENT <= set(ingredient)
    for step in body["steps"]:
        assert PRD_10_1_STEP <= set(step)


async def test_additive_stored_fields_never_break_public_get(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    ids = await seed(db_session)
    # Versions are append-only; simulating a future additive column needs the operator unlock.
    await db_session.execute(text("set local souslens.unlock_versions = 'on'"))
    await db_session.execute(
        text(
            """
            update recipe_versions set
              step_json = (
                select jsonb_agg(s || '{"future_field": 1}'::jsonb)
                from jsonb_array_elements(step_json) s
              ),
              ingredient_json = (
                select jsonb_agg(i || '{"brand": "x"}'::jsonb)
                from jsonb_array_elements(ingredient_json) i
              ),
              warning_json = warning_json || '{"allergen_matrix": {}}'::jsonb
            """
        )
    )
    await db_session.commit()
    response = await client.get(f"/v1/recipes/{ids[GOCHUJANG]}")
    assert response.status_code == 200, response.text
    body = response.json()
    assert "future_field" not in body["steps"][0]
    assert "brand" not in body["ingredients"][0]
    assert "allergen_matrix" not in body


async def test_reseed_does_not_republish_an_unpublished_seeded_recipe(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    ids = await seed(db_session)
    await db_session.execute(
        text("update recipes set visibility = 'private' where slug = :slug"), {"slug": GOCHUJANG}
    )
    await db_session.commit()
    await seed_fixtures(db_session, FIXTURES_DIR)
    assert slugs(await client.get("/v1/recipes")) == SEED_SLUGS_NEWEST_FIRST[1:]
    assert (await client.get(f"/v1/recipes/{ids[GOCHUJANG]}")).status_code == 404


async def test_control_characters_in_search_params_are_422_not_500(client: AsyncClient) -> None:
    for params, field in (
        ({"query": "a\x00b"}, "query.query"),
        ({"query": "a\u202eb"}, "query.query"),
        ({"query": "a\nb"}, "query.query"),
        ({"tag": "\x00"}, "query.tag"),
    ):
        response = await client.get("/v1/recipes", params=params)
        assert response.status_code == 422, (params, response.text)
        assert response.json()["error"]["fields"] == [field]
