"""Brief 015: For You ranking and the Following feed over the five seeded recipes."""

from __future__ import annotations

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from app.domains.feed.service import diet_mismatch
from app.scripts.seed import seed_fixtures
from tests.conftest import FIXTURES_DIR, dev_sign_in

PASTA = [
    "spaghetti",
    "garlic",
    "extra-virgin olive oil",
    "red pepper flakes",
    "kosher salt",
    "flat-leaf parsley",
    "parmesan",
    "lemon",
]


async def _setup(client: AsyncClient, db_session: AsyncSession) -> dict[str, str]:
    await seed_fixtures(db_session, FIXTURES_DIR)
    await db_session.commit()
    token = await dev_sign_in(client, "alice@example.com")
    return {"Authorization": f"Bearer {token}"}


async def _feed(client: AsyncClient, h: dict[str, str], path: str = "for-you") -> list[dict]:
    r = await client.get(f"/v1/feed/{path}?limit=50", headers=h)
    assert r.status_code == 200, r.text
    return r.json()["items"]


def _slugs(items: list[dict]) -> list[str]:
    return [i["slug"] for i in items]


async def test_for_you_without_pantry_or_prefs_is_newest_first(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    h = await _setup(client, db_session)
    items = await _feed(client, h)
    assert len(items) == 5
    dates = [i["published_at"] for i in items]
    assert dates == sorted(dates, reverse=True)
    for item in items:
        assert item["feed"] == {
            "reason": "New",
            "coverage": None,
            "can_make": False,
            "allergy_conflict": None,
        }


async def test_pantry_fit_ranks_first_with_have_reason(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    h = await _setup(client, db_session)
    items = [{"raw_label": x, "quantity": None, "unit": None, "source": "manual"} for x in PASTA]
    assert (await client.post("/v1/pantry", json={"items": items}, headers=h)).status_code == 201
    feed = await _feed(client, h)
    top = feed[0]
    assert top["slug"] == "garlic-pasta"
    assert top["feed"]["coverage"] == 1.0
    assert top["feed"]["reason"].startswith("You have ")
    assert all(i["feed"]["reason"].startswith("You have ") for i in feed)
    coverages = [i["feed"]["coverage"] for i in feed]
    assert coverages == sorted(coverages, reverse=True)


async def test_cuisine_boost_and_allergy_conflicts_sort_last(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    h = await _setup(client, db_session)
    prefs = {"allergies": ["eggs"], "avoid": [], "cuisines": ["korean"]}
    assert (await client.put("/v1/me/preferences", json=prefs, headers=h)).status_code == 200
    feed = await _feed(client, h)

    flagged = [i for i in feed if i["feed"]["allergy_conflict"]]
    assert set(_slugs(flagged)) == {"egg-and-tomato-stir-fry", "kimchi-fried-rice"}
    assert all(i["feed"]["allergy_conflict"] == "egg" for i in flagged)
    assert _slugs(feed[-2:]) == _slugs(flagged)  # after every other recipe, still visible
    assert feed[0]["slug"] == "gochujang-chicken-thighs"
    assert feed[0]["feed"]["reason"] == "Korean"
    assert "safe" not in str(feed).lower()


async def test_diet_lowers_but_keeps(client: AsyncClient, db_session: AsyncSession) -> None:
    h = await _setup(client, db_session)
    prefs = {"allergies": [], "avoid": [], "diets": ["vegetarian"]}
    await client.put("/v1/me/preferences", json=prefs, headers=h)
    feed = await _feed(client, h)
    assert len(feed) == 5
    assert feed[-1]["slug"] == "gochujang-chicken-thighs"


async def test_following_feed(client: AsyncClient, db_session: AsyncSession) -> None:
    h = await _setup(client, db_session)
    assert await _feed(client, h, "following") == []
    creator_id = (await _feed(client, h))[0]["creator"]["id"]
    await client.put(f"/v1/creators/{creator_id}/follow", headers=h)
    following = await _feed(client, h, "following")
    assert len(following) == 5
    dates = [i["published_at"] for i in following]
    assert dates == sorted(dates, reverse=True)
    for_you = await _feed(client, h)
    assert all(i["feed"]["reason"].startswith("From ") for i in for_you)


async def test_paging_covers_everything_once(client: AsyncClient, db_session: AsyncSession) -> None:
    h = await _setup(client, db_session)
    for path in ("for-you", "following"):
        if path == "following":
            creator_id = (await _feed(client, h))[0]["creator"]["id"]
            await client.put(f"/v1/creators/{creator_id}/follow", headers=h)
        seen: list[str] = []
        cursor = None
        while True:
            q = f"/v1/feed/{path}?limit=2" + (f"&cursor={cursor}" if cursor else "")
            body = (await client.get(q, headers=h)).json()
            seen += _slugs(body["items"])
            cursor = body["next_cursor"]
            if cursor is None:
                break
        assert len(seen) == len(set(seen)) == 5, path

    for bad in ("x", "o-1", "o12345678"):
        r = await client.get(f"/v1/feed/for-you?cursor={bad}", headers=h)
        assert r.status_code == 422, bad
    assert (await client.get("/v1/feed/for-you")).status_code == 401


def test_diet_mismatch_rules() -> None:
    assert not diet_mismatch([], ["korean"])
    assert not diet_mismatch(["vegetarian"], ["vegan"])
    assert not diet_mismatch(["vegetarian"], ["vegetarian-option"])
    assert not diet_mismatch(["pescatarian"], ["vegetarian"])
    assert diet_mismatch(["vegan"], ["vegetarian"])
    assert diet_mismatch(["halal"], ["korean"])
