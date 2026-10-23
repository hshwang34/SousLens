"""Brief 003 backend gate probes: immutability, concurrency, ownership, search, saves, URLs."""

from __future__ import annotations

import asyncio
import json
import uuid

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession

from app.core.config import Settings
from app.db.models import DraftStatus, RecipeDraft
from app.domains.recipes import drafts as draft_service
from app.domains.recipes.draft_schemas import DraftPatch
from app.domains.users import service as users_service
from app.main import create_app
from app.scripts.seed import seed_fixtures
from tests.conftest import FIXTURES_DIR, bearer, draft_payload
from tests.integration.test_publish import publish_new

VERSION_FIELDS = (
    "ingredients",
    "steps",
    "creator_notes",
    "dietary_warnings",
    "servings",
    "prep_minutes",
    "cook_minutes",
)


def canon(obj: object) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


# --------------------------------------------------------------------------- 1. immutability


async def test_v1_version_fields_byte_identical_after_v2_and_unpublish(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    alice = await bearer(client, "alice@example.com")
    v1 = await publish_new(client, alice)
    url1 = f"/v1/recipe-versions/{v1['recipe_version_id']}"
    before = (await client.get(url1, headers=alice)).json()

    draft = (
        await client.post(f"/v1/recipes/{v1['recipe_id']}/edit", json={}, headers=alice)
    ).json()
    patch = {
        "ingredients": [{"id": "ing-9", "name": "chili oil", "quantity": 1, "unit": "tbsp"}],
        "steps": [{"id": "step-9", "instruction": "Drizzle.", "ingredient_refs": ["ing-9"]}],
        "servings": 9,
        "prep_minutes": 99,
        "cook_minutes": 98,
        "creator_notes": ["changed"],
        "dietary_warnings": ["changed"],
    }
    await client.patch(f"/v1/recipes/drafts/{draft['id']}", json=patch, headers=alice)
    published = await client.post(
        f"/v1/recipes/drafts/{draft['id']}/publish", json={}, headers=alice
    )
    assert published.json()["version_number"] == 2
    await client.post(f"/v1/recipes/{v1['recipe_id']}/unpublish", json={}, headers=alice)

    after = (await client.get(url1, headers=alice)).json()
    for key in VERSION_FIELDS:
        assert canon(after[key]) == canon(before[key]), key
    assert after["version_number"] == 1
    assert after["recipe_version_id"] == before["recipe_version_id"]


async def test_whole_v1_json_is_unchanged_after_v2(client: AsyncClient) -> None:
    """The brief's gate is "v1 JSON unchanged (byte-equal)": every key, title included."""
    alice = await bearer(client, "alice@example.com")
    v1 = await publish_new(client, alice)
    url1 = f"/v1/recipe-versions/{v1['recipe_version_id']}"
    before = (await client.get(url1, headers=alice)).text
    draft = (
        await client.post(f"/v1/recipes/{v1['recipe_id']}/edit", json={}, headers=alice)
    ).json()
    await client.patch(
        f"/v1/recipes/drafts/{draft['id']}",
        json={"title": "Renamed", "summary": "New", "tags": ["x"]},
        headers=alice,
    )
    await client.post(f"/v1/recipes/drafts/{draft['id']}/publish", json={}, headers=alice)
    after = (await client.get(url1, headers=alice)).text
    assert after == before
    # ... and after unpublish (same caller, so the caller-dependent saved/share_url match too).
    await client.post(f"/v1/recipes/{v1['recipe_id']}/unpublish", json={}, headers=alice)
    assert (await client.get(url1, headers=alice)).text == before
    assert json.loads(before)["title"] == "Weeknight Garlic Noodles"


async def test_raw_sql_update_delete_and_fk_cascades_are_blocked(db_session: AsyncSession) -> None:

    from sqlalchemy.exc import DBAPIError

    results = await seed_fixtures(db_session, FIXTURES_DIR)
    for sql in (
        "update recipe_versions set step_json='[]'::jsonb",
        "update recipe_versions set search_text='x'",
        "delete from recipe_versions",
        "delete from recipes",
        "delete from users",
        "truncate recipe_versions",
    ):
        try:
            with pytest.raises(DBAPIError, match=r"append-only|cannot truncate|violates"):
                await db_session.execute(text(sql))
        finally:
            await db_session.rollback()
    count = (await db_session.execute(text("select count(*) from recipe_versions"))).scalar_one()
    assert count == len(results) == 5


# --------------------------------------------------------------------------- 2. concurrency


def _client_for(settings: Settings) -> AsyncClient:
    app = create_app(settings)
    return AsyncClient(
        transport=ASGITransport(app=app, raise_app_exceptions=False), base_url="http://test"
    )


async def test_concurrent_publish_of_two_drafts_for_one_recipe_gets_distinct_versions(
    client: AsyncClient, engine: AsyncEngine, db_session: AsyncSession
) -> None:
    alice = await bearer(client, "alice@example.com")
    v1 = await publish_new(client, alice)
    user_id = (await client.get("/v1/me", headers=alice)).json()["id"]
    ids = []
    for title in ("Concurrent A", "Concurrent B", "Concurrent C"):
        row = RecipeDraft(
            owner_user_id=uuid.UUID(user_id),
            recipe_id=uuid.UUID(v1["recipe_id"]),
            structured_draft_json=draft_service.normalise(
                draft_service.apply_patch(
                    draft_service.DraftContent(), DraftPatch(**draft_payload(title=title))
                )
            ),
            status=DraftStatus.EDITING,
        )
        db_session.add(row)
        await db_session.flush()
        ids.append(str(row.id))
    await db_session.commit()

    responses = await asyncio.gather(
        *(client.post(f"/v1/recipes/drafts/{i}/publish", json={}, headers=alice) for i in ids)
    )
    assert [r.status_code for r in responses] == [201, 201, 201], [r.text for r in responses]
    numbers = sorted(r.json()["version_number"] for r in responses)
    assert numbers == [2, 3, 4]
    async with engine.connect() as conn:
        rows = (
            await conn.execute(
                text(
                    "select version_number, count(*) from recipe_versions "
                    "where recipe_id = :r group by 1 order by 1"
                ),
                {"r": v1["recipe_id"]},
            )
        ).all()
        latest = (
            await conn.execute(
                text(
                    "select v.version_number from recipes r join recipe_versions v "
                    "on v.id = r.latest_version_id where r.id = :r"
                ),
                {"r": v1["recipe_id"]},
            )
        ).scalar_one()
    assert [(n, c) for n, c in rows] == [(1, 1), (2, 1), (3, 1), (4, 1)]
    assert latest == 4


async def test_concurrent_first_publishes_with_same_title_never_500(
    client: AsyncClient,
) -> None:
    alice = await bearer(client, "alice@example.com")
    bob = await bearer(client, "bob@example.com")
    ids = []
    for who in (alice, bob, alice, bob, alice, bob):
        draft = (
            await client.post(
                "/v1/recipes/drafts", json=draft_payload(title="Same Title"), headers=who
            )
        ).json()
        ids.append((draft["id"], who))
    responses = await asyncio.gather(
        *(client.post(f"/v1/recipes/drafts/{i}/publish", json={}, headers=h) for i, h in ids)
    )
    codes = [r.status_code for r in responses]
    assert all(c in (201, 409) for c in codes), [(r.status_code, r.text) for r in responses]
    for r in responses:
        if r.status_code != 201:
            assert "Traceback" not in r.text and "sqlalchemy" not in r.text.lower()
    slugs = []
    for r in responses:
        if r.status_code == 201:
            slugs.append((await client.get(f"/v1/recipes/{r.json()['recipe_id']}")).json()["slug"])
    assert len(slugs) == len(set(slugs)) and slugs


async def test_concurrent_saves_by_one_user_leave_one_row(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    ids = {r.slug: str(r.recipe_id) for r in await seed_fixtures(db_session, FIXTURES_DIR)}
    await db_session.commit()
    alice = await bearer(client, "alice@example.com")
    rid = ids["garlic-pasta"]
    responses = await asyncio.gather(
        *(client.post(f"/v1/recipes/{rid}/save", headers=alice) for _ in range(8))
    )
    assert [r.status_code for r in responses] == [200] * 8, [r.text for r in responses]
    count = (
        await db_session.execute(
            text("select count(*) from saves where recipe_id = :r"), {"r": rid}
        )
    ).scalar_one()
    assert count == 1
    unsaves = await asyncio.gather(
        *(client.delete(f"/v1/recipes/{rid}/save", headers=alice) for _ in range(8))
    )
    assert [r.status_code for r in unsaves] == [200] * 8, [r.text for r in unsaves]
    assert (await client.get("/v1/me/saved", headers=alice)).json()["items"] == []


# --------------------------------------------------------------------------- 3. ownership


async def test_foreign_recipe_and_draft_errors_are_identical_to_missing_ids(
    client: AsyncClient,
) -> None:
    alice = await bearer(client, "alice@example.com")
    bob = await bearer(client, "bob@example.com")
    v1 = await publish_new(client, alice)
    rid, did = v1["recipe_id"], v1["draft"]["id"]
    other = (await client.post("/v1/recipes/drafts", json={"title": "A"}, headers=alice)).json()

    def shape(r) -> tuple[int, str, str]:
        body = r.json()["error"]
        return r.status_code, body["code"], body["message"]

    async def calls(rec: str, dr: str) -> list[tuple[int, str, str]]:
        d = f"/v1/recipes/drafts/{dr}"
        return [
            shape(await client.get(d, headers=bob)),
            shape(await client.patch(d, json={"title": "x"}, headers=bob)),
            shape(await client.delete(d, headers=bob)),
            shape(await client.post(f"{d}/publish", json={}, headers=bob)),
            shape(await client.post(f"/v1/recipes/{rec}/edit", json={}, headers=bob)),
            shape(await client.post(f"/v1/recipes/{rec}/unpublish", json={}, headers=bob)),
        ]

    foreign = await calls(rid, other["id"])
    missing = await calls(str(uuid.uuid4()), str(uuid.uuid4()))
    assert all(s[0] == 404 for s in foreign)
    assert foreign == missing
    # Nothing changed for the owner.
    assert (await client.get(f"/v1/recipes/{rid}")).status_code == 200
    assert (await client.get(f"/v1/recipes/drafts/{did}", headers=alice)).status_code == 200


async def test_anonymous_cannot_touch_draft_endpoints(client: AsyncClient) -> None:
    alice = await bearer(client, "alice@example.com")
    draft = (await client.post("/v1/recipes/drafts", json={}, headers=alice)).json()
    d = f"/v1/recipes/drafts/{draft['id']}"
    for r in (
        await client.post("/v1/recipes/drafts", json={}),
        await client.get("/v1/recipes/drafts"),
        await client.get(d),
        await client.patch(d, json={}),
        await client.delete(d),
        await client.post(f"{d}/publish", json={}),
        await client.post(f"/v1/recipes/{uuid.uuid4()}/edit", json={}),
        await client.get("/v1/me/recipes"),
    ):
        assert r.status_code == 401, (r.request.url, r.text)
        assert r.json()["error"]["code"] == "UNAUTHENTICATED" or r.json()["error"]["code"]


# --------------------------------------------------------------------------- 4. search


async def test_search_never_surfaces_unpublished_or_draft_ingredients(
    client: AsyncClient,
) -> None:
    alice = await bearer(client, "alice@example.com")
    ingredients = [{"id": "ing-1", "name": "dragonfruit", "quantity": 1, "unit": "ea"}]
    steps = [{"id": "step-1", "instruction": "Peel.", "ingredient_refs": ["ing-1"]}]
    # draft only
    await client.post(
        "/v1/recipes/drafts",
        json=draft_payload(title="Only Draft", ingredients=ingredients, steps=steps),
        headers=alice,
    )
    assert (await client.get("/v1/recipes", params={"query": "dragonfruit"})).json()["items"] == []
    # published then unpublished
    pub = await publish_new(
        client, alice, title="Pitaya Bowl", ingredients=ingredients, steps=steps
    )
    hit = (await client.get("/v1/recipes", params={"query": "dragonfruit"})).json()["items"]
    assert [c["title"] for c in hit] == ["Pitaya Bowl"]
    await client.post(f"/v1/recipes/{pub['recipe_id']}/unpublish", json={}, headers=alice)
    for who in ({}, alice):
        r = await client.get("/v1/recipes", params={"query": "dragonfruit"}, headers=who)
        assert r.json()["items"] == []
        r = await client.get("/v1/recipes", params={"query": "Pitaya"}, headers=who)
        assert r.json()["items"] == []


async def test_search_uses_latest_version_ingredients_and_like_wildcards_are_literal(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await seed_fixtures(db_session, FIXTURES_DIR)
    await db_session.commit()
    for q in ("%", "_", "\\", "%%", "g_ochujang", "gochujang%", "%chicken", "c_icken", "a\\b"):
        r = await client.get("/v1/recipes", params={"query": q})
        assert r.status_code == 200, q
        assert r.json()["items"] == [], q
    alice = await bearer(client, "alice@example.com")
    pct = await publish_new(
        client,
        alice,
        title="100% Juice_Bar",
        ingredients=[{"id": "ing-1", "name": "lime", "quantity": 1}],
        steps=[{"id": "step-1", "instruction": "Squeeze."}],
    )
    for q, expected in (
        ("100%", 1),
        ("juice_bar", 1),
        ("e_b", 1),
        ("%", 1),
        ("_", 1),
        ("j_ice", 0),
    ):
        items = (await client.get("/v1/recipes", params={"query": q})).json()["items"]
        assert len(items) == expected, (q, [c["title"] for c in items])
    assert pct["version_number"] == 1


async def test_empty_query_returns_all_five_published_at_desc(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await seed_fixtures(db_session, FIXTURES_DIR)
    await db_session.commit()
    plain = (await client.get("/v1/recipes")).json()["items"]
    empty = (await client.get("/v1/recipes", params={"query": ""})).json()["items"]
    assert len(plain) == 5 and plain == empty
    stamps = [c["published_at"] for c in plain]
    assert stamps == sorted(stamps, reverse=True)


# --------------------------------------------------------------------------- 5. saves


async def test_saved_recipe_unpublished_leaves_saved_list_but_version_stays_readable(
    client: AsyncClient,
) -> None:
    alice = await bearer(client, "alice@example.com")
    bob = await bearer(client, "bob@example.com")
    a = await publish_new(client, alice, title="Alpha")
    b = await publish_new(client, alice, title="Beta")
    for p in (a, b):
        await client.post(f"/v1/recipes/{p['recipe_id']}/save", headers=bob)
    assert [
        c["title"] for c in (await client.get("/v1/me/saved", headers=bob)).json()["items"]
    ] == [
        "Beta",
        "Alpha",
    ]
    await client.post(f"/v1/recipes/{b['recipe_id']}/unpublish", json={}, headers=alice)
    assert [
        c["title"] for c in (await client.get("/v1/me/saved", headers=bob)).json()["items"]
    ] == ["Alpha"]
    r = await client.get(f"/v1/recipe-versions/{b['recipe_version_id']}", headers=bob)
    assert r.status_code == 200 and r.json()["title"] == "Beta"
    # Re-publish brings it back to the saved list.
    draft = (await client.post(f"/v1/recipes/{b['recipe_id']}/edit", json={}, headers=alice)).json()
    await client.post(f"/v1/recipes/drafts/{draft['id']}/publish", json={}, headers=alice)
    assert len((await client.get("/v1/me/saved", headers=bob)).json()["items"]) == 2


# --------------------------------------------------------------------------- 6. validation


async def test_cover_url_length_boundary_and_credentials(client: AsyncClient) -> None:
    alice = await bearer(client, "alice@example.com")
    draft = (await client.post("/v1/recipes/drafts", json={}, headers=alice)).json()
    url = f"/v1/recipes/drafts/{draft['id']}"
    prefix = "https://a.example/"
    ok = prefix + "x" * (2048 - len(prefix))
    too_long = prefix + "x" * (2049 - len(prefix))
    assert len(ok) == 2048 and len(too_long) == 2049
    assert (await client.patch(url, json={"cover_image_url": ok}, headers=alice)).status_code == 200
    r = await client.patch(url, json={"cover_image_url": too_long}, headers=alice)
    assert r.status_code == 422 and r.json()["error"]["fields"] == ["body.cover_image_url"]
    for bad in (
        "http://a.example/x",
        "javascript:alert(1)",
        "https://user:pw@host.example/x.jpg",
        "HTTP://a.example/x",
        "data:image/png;base64,AAAA",
    ):
        r = await client.patch(url, json={"cover_image_url": bad}, headers=alice)
        assert r.status_code == 422, bad


async def test_publish_each_rule_is_its_own_problem_entry(client: AsyncClient) -> None:
    alice = await bearer(client, "alice@example.com")
    cases = {
        "title": draft_payload(title="   "),
        "servings": draft_payload(servings=None),
        "ingredients": draft_payload(ingredients=[], steps=[{"id": "s", "instruction": "x"}]),
        "steps": draft_payload(steps=[]),
    }
    for field, payload in cases.items():
        draft = (await client.post("/v1/recipes/drafts", json=payload, headers=alice)).json()
        r = await client.post(f"/v1/recipes/drafts/{draft['id']}/publish", json={}, headers=alice)
        assert r.status_code == 422, field
        problems = r.json()["error"]["details"]["problems"]
        assert [p["field"] for p in problems] == [field], (field, problems)
        assert problems == draft["validation"]["problems"]
    # Draft remains unpublished and the feed empty.
    assert (await client.get("/v1/recipes")).json()["items"] == []


# --------------------------------------------------------------------------- 7. seed / fixture


async def test_live_anonymous_list_equals_fixture_semantically_and_in_key_order(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await seed_fixtures(db_session, FIXTURES_DIR)
    await db_session.commit()
    live = (await client.get("/v1/recipes")).json()
    path = FIXTURES_DIR / "expected_outputs" / "recipes_list.json"
    fixture = json.loads(path.read_text(encoding="utf-8"))
    assert live == fixture
    # Fixture file is the live body pretty-printed (indent=2) plus a trailing newline.
    assert json.dumps(live, indent=2, ensure_ascii=False) + "\n" == path.read_text(encoding="utf-8")


async def test_double_seed_keeps_five_recipes_and_dedupes_users(db_session: AsyncSession) -> None:
    await seed_fixtures(db_session, FIXTURES_DIR)
    await seed_fixtures(db_session, FIXTURES_DIR)
    await db_session.commit()
    for table, expected in (("recipes", 5), ("recipe_versions", 5)):
        n = (await db_session.execute(text(f"select count(*) from {table}"))).scalar_one()
        assert n == expected, table
    assert users_service  # imported for parity with sibling tests
