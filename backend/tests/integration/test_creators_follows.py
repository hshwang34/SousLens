"""Brief 015: creators, follows and onboarding suggestions."""

from __future__ import annotations

import uuid

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.scripts.seed import seed_fixtures
from tests.conftest import FIXTURES_DIR, dev_sign_in


async def _sign_in(client: AsyncClient, email: str) -> tuple[dict[str, str], str]:
    headers = {"Authorization": f"Bearer {await dev_sign_in(client, email)}"}
    me = (await client.get("/v1/me", headers=headers)).json()
    return headers, me["id"]


async def _seed_two_creators(client: AsyncClient, db_session: AsyncSession) -> dict[str, str]:
    """Seeded recipes all belong to the seed owner; hand the Korean ones to a second creator."""
    await seed_fixtures(db_session, FIXTURES_DIR)
    _, mina_id = await _sign_in(client, "mina@example.com")
    await db_session.execute(
        text("update recipes set owner_user_id = :m where 'korean' = any(tags)"),
        {"m": uuid.UUID(mina_id)},
    )
    await db_session.execute(
        text("update users set bio = 'Weeknight Korean.' where id = :m"), {"m": uuid.UUID(mina_id)}
    )
    seed_owner = (
        await db_session.execute(
            text("select owner_user_id from recipes where not ('korean' = any(tags)) limit 1")
        )
    ).scalar_one()
    await db_session.commit()
    return {"mina": mina_id, "kitchen": str(seed_owner)}


async def test_suggested_ranks_by_cuisine_and_excludes_self(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    ids = await _seed_two_creators(client, db_session)
    alice, _ = await _sign_in(client, "alice@example.com")

    r = await client.get("/v1/creators/suggested?cuisines=korean", headers=alice)
    assert r.status_code == 200, r.text
    items = r.json()["items"]
    assert [c["id"] for c in items][:1] == [ids["mina"]]
    mina = items[0]
    assert mina["bio"] == "Weeknight Korean."
    assert "korean" in mina["cuisines"]
    assert mina["recipe_count"] >= 1
    assert 1 <= len(mina["sample_recipe_titles"]) <= 2
    assert mina["is_following"] is False
    assert {c["id"] for c in items} == {ids["mina"], ids["kitchen"]}

    mina_headers, _ = await _sign_in(client, "mina@example.com")
    mine = (await client.get("/v1/creators/suggested", headers=mina_headers)).json()["items"]
    assert ids["mina"] not in {c["id"] for c in mine}

    bad = await client.get("/v1/creators/suggested?cuisines=martian", headers=alice)
    assert bad.status_code == 422
    assert (await client.get("/v1/creators/suggested")).status_code == 401


async def test_follow_unfollow_idempotent_and_following_list(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    ids = await _seed_two_creators(client, db_session)
    alice, _ = await _sign_in(client, "alice@example.com")
    url = f"/v1/creators/{ids['mina']}/follow"

    for _ in range(2):
        r = await client.put(url, headers=alice)
        assert r.status_code == 200, r.text
        assert r.json()["is_following"] is True
        assert r.json()["follower_count"] == 1
    await client.put(f"/v1/creators/{ids['kitchen']}/follow", headers=alice)

    following = (await client.get("/v1/me/following", headers=alice)).json()["items"]
    assert [c["id"] for c in following] == [ids["kitchen"], ids["mina"]]

    for _ in range(2):
        r = await client.delete(url, headers=alice)
        assert r.status_code == 200
        assert r.json()["is_following"] is False
        assert r.json()["follower_count"] == 0
    following = (await client.get("/v1/me/following", headers=alice)).json()["items"]
    assert [c["id"] for c in following] == [ids["kitchen"]]

    bob, _ = await _sign_in(client, "bob@example.com")
    assert (await client.get("/v1/me/following", headers=bob)).json()["items"] == []


async def test_cannot_follow_self_non_creator_or_unknown(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    ids = await _seed_two_creators(client, db_session)
    mina, _ = await _sign_in(client, "mina@example.com")
    _, bob_id = await _sign_in(client, "bob@example.com")

    for target in (ids["mina"], bob_id, str(uuid.uuid4()), "not-a-uuid"):
        r = await client.put(f"/v1/creators/{target}/follow", headers=mina)
        assert r.status_code == 404, (target, r.text)
    assert (await client.put(f"/v1/creators/{ids['kitchen']}/follow")).status_code == 401


async def test_creator_profile(client: AsyncClient, db_session: AsyncSession) -> None:
    ids = await _seed_two_creators(client, db_session)
    alice, _ = await _sign_in(client, "alice@example.com")
    await client.put(f"/v1/creators/{ids['mina']}/follow", headers=alice)

    r = await client.get(f"/v1/creators/{ids['mina']}", headers=alice)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["creator"]["is_following"] is True
    assert body["recipes"]
    assert all(card["creator"]["id"] == ids["mina"] for card in body["recipes"])
    dates = [card["published_at"] for card in body["recipes"]]
    assert dates == sorted(dates, reverse=True)
    assert body["creator"]["recipe_count"] == len(body["recipes"])

    anon = (await client.get(f"/v1/creators/{ids['mina']}")).json()
    assert anon["creator"]["is_following"] is False

    _, bob_id = await _sign_in(client, "bob@example.com")
    assert (await client.get(f"/v1/creators/{bob_id}", headers=alice)).status_code == 404


async def test_unfollow_after_creator_unpublished_everything(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    ids = await _seed_two_creators(client, db_session)
    alice, _ = await _sign_in(client, "alice@example.com")
    await client.put(f"/v1/creators/{ids['mina']}/follow", headers=alice)
    await db_session.execute(
        text("update recipes set visibility = 'private' where owner_user_id = :m"),
        {"m": uuid.UUID(ids["mina"])},
    )
    await db_session.commit()

    assert (await client.get("/v1/me/following", headers=alice)).json()["items"] == []
    r = await client.delete(f"/v1/creators/{ids['mina']}/follow", headers=alice)
    assert r.status_code == 200
    assert r.json()["recipe_count"] == 0
    assert r.json()["is_following"] is False
    assert r.json()["bio"] is None
    # Nothing left to drop: a non-creator now answers 404 like any unknown id.
    again = await client.delete(f"/v1/creators/{ids['mina']}/follow", headers=alice)
    assert again.status_code == 404


async def test_unfollow_never_reveals_non_creators(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await _seed_two_creators(client, db_session)
    alice, _ = await _sign_in(client, "alice@example.com")
    _, bob_id = await _sign_in(client, "bob@example.com")
    r = await client.delete(f"/v1/creators/{bob_id}/follow", headers=alice)
    assert r.status_code == 404
    assert "bob" not in r.text
