"""Brief 005 QA gate (backend): rate limits and caps (security review of brief 005)."""

from __future__ import annotations

import asyncio

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.providers.base import CoachRequest
from tests.conftest import bearer
from tests.integration.slice3_helpers import command, ok, seed, start_session
from tests.integration.test_ask_api import CapturingCoach, use

GOCHU = "gochujang-chicken-thighs"


async def _uid(db: AsyncSession, email: str):
    return await db.scalar(text("select id from users where email = :e"), {"e": email})


async def _ledger(db: AsyncSession, uid, kind: str) -> int:
    await db.rollback()
    return int(
        await db.scalar(
            text("select count(*) from usage_events where user_id = :u and kind = :k"),
            {"u": uid, "k": kind},
        )
        or 0
    )


async def _seed_usage(db: AsyncSession, uid, kind: str, n: int) -> None:
    await db.execute(
        text(
            "insert into usage_events (id, user_id, kind, created_at) "
            "select gen_random_uuid(), :u, :k, now() "
            "from generate_series(1, :n)"
        ),
        {"u": uid, "k": kind, "n": n},
    )
    await db.commit()


async def test_open_session_cap_lists_newest_first_and_resume_or_abandon_frees_a_slot(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    uid = await _uid(db_session, "alice@example.com")
    made = [await start_session(client, alice, versions[GOCHU]) for _ in range(3)]
    # touching the oldest makes it the newest (ordering follows updated_at)
    made[0] = ok(await command(client, alice, made[0], "start"))
    r = await client.post(
        "/v1/sessions", json={"recipe_version_id": versions[GOCHU]}, headers=alice
    )
    assert r.status_code == 409 and r.json()["error"]["code"] == "STATE_CONFLICT"
    ids = r.json()["error"]["details"]["open_session_ids"]
    assert ids == [made[0]["id"], made[2]["id"], made[1]["id"]]
    listed = ok(await client.get("/v1/sessions?status=active", headers=alice))["items"]
    assert [i["id"] for i in listed] == ids
    assert await _ledger(db_session, uid, "session_created") == 3  # the refused 4th cost nothing
    # completed/abandoned sessions are not open
    ok(await command(client, alice, made[1], "abandon"))
    await start_session(client, alice, versions[GOCHU])
    # another user is unaffected
    bob = await bearer(client, "bob@example.com")
    await start_session(client, bob, versions[GOCHU])


async def test_31st_creation_in_an_hour_is_429_even_if_sessions_are_abandoned_or_deleted(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    uid = await _uid(db_session, "alice@example.com")
    for i in range(30):
        s = await start_session(client, alice, versions[GOCHU])
        if i % 2:
            assert (
                await client.delete(f"/v1/sessions/{s['id']}", headers=alice)
            ).status_code == 204
        else:
            ok(await command(client, alice, s, "abandon"))
    assert await _ledger(db_session, uid, "session_created") == 30
    r = await client.post(
        "/v1/sessions", json={"recipe_version_id": versions[GOCHU]}, headers=alice
    )
    assert r.status_code == 429 and r.json()["error"]["code"] == "RATE_LIMITED"
    assert await _ledger(db_session, uid, "session_created") == 30
    open_now = ok(await client.get("/v1/sessions?status=active", headers=alice))["items"]
    assert open_now == []  # nothing was created by the refused call
    # events older than the one hour window no longer count
    await db_session.execute(
        text(
            "update usage_events set created_at = now() - interval '61 minutes' where user_id = :u"
        ),
        {"u": uid},
    )
    await db_session.commit()
    await start_session(client, alice, versions[GOCHU])


async def test_failed_creation_does_not_consume_the_creation_budget(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    uid = await _uid(db_session, "alice@example.com")
    bad = {"ingredient_ref": "ing-99", "replacement": "x", "source": "ai"}
    r = await client.post(
        "/v1/sessions",
        json={"recipe_version_id": versions[GOCHU], "adaptations": [bad]},
        headers=alice,
    )
    assert r.status_code == 422
    assert await _ledger(db_session, uid, "session_created") == 0


async def test_which_asks_count_against_the_budget(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """Counted: every ask that reaches the coach, including provider failures (cost control).
    Not counted: validation errors (422), closed sessions (409), foreign sessions (404)."""
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    bob = await bearer(client, "bob@example.com")
    uid = await _uid(db_session, "alice@example.com")
    s = ok(
        await command(client, alice, await start_session(client, alice, versions[GOCHU]), "start")
    )

    async def ask(q: str, headers=alice, session=s):
        return await client.post(
            f"/v1/sessions/{session['id']}/ask", json={"query": q}, headers=headers
        )

    assert (await ask("x" * 501)).status_code == 422
    assert (await ask("  ")).status_code == 422
    assert (await ask("hi", headers=bob)).status_code == 404
    assert await _ledger(db_session, uid, "ask") == 0
    assert (await ask("what now?")).status_code == 200
    assert await _ledger(db_session, uid, "ask") == 1
    use(client, CapturingCoach(lambda req: {"answer_text": 5}))  # malformed twice -> 502
    assert (await ask("what now?")).status_code == 502
    assert await _ledger(db_session, uid, "ask") == 2  # a failed ask still counts

    def boom(req: CoachRequest):
        raise RuntimeError("provider down")

    use(client, CapturingCoach(boom))
    assert (await ask("what now?")).status_code == 503
    assert await _ledger(db_session, uid, "ask") == 3
    done = ok(await command(client, alice, s, "abandon"))
    assert (await ask("hi", session=done)).status_code == 409
    assert await _ledger(db_session, uid, "ask") == 3


async def test_ask_budget_is_exact_under_concurrency_and_ages_out(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    uid = await _uid(db_session, "alice@example.com")
    sessions = [
        ok(
            await command(
                client, alice, await start_session(client, alice, versions[GOCHU]), "start"
            )
        )
        for _ in range(3)
    ]
    await _seed_usage(db_session, uid, "ask", 110)
    rs = await asyncio.gather(
        *(
            client.post(
                f"/v1/sessions/{sessions[i % 3]['id']}/ask",
                json={"query": f"q{i}"},
                headers=alice,
            )
            for i in range(30)
        )
    )
    codes = sorted(r.status_code for r in rs)
    assert codes == [200] * 10 + [429] * 20, codes
    assert await _ledger(db_session, uid, "ask") == 120
    # the window slides: an hour later the budget is back
    await db_session.execute(
        text(
            "update usage_events set created_at = now() - interval '61 minutes' where user_id = :u"
        ),
        {"u": uid},
    )
    await db_session.commit()
    r = await client.post(
        f"/v1/sessions/{sessions[0]['id']}/ask", json={"query": "again"}, headers=alice
    )
    assert r.status_code == 200


async def test_per_session_cap_is_independent_of_the_user_budget(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    uid = await _uid(db_session, "alice@example.com")
    a = ok(
        await command(client, alice, await start_session(client, alice, versions[GOCHU]), "start")
    )
    b = ok(
        await command(client, alice, await start_session(client, alice, versions[GOCHU]), "start")
    )
    await db_session.execute(
        text(
            "insert into session_messages "
            "(id, session_id, role, text, source_refs_json, created_at) "
            "select gen_random_uuid(), :s, 'user', 'q', '[]'::jsonb, now() "
            "from generate_series(1, 60)"
        ),
        {"s": a["id"]},
    )
    await db_session.commit()
    r = await client.post(f"/v1/sessions/{a['id']}/ask", json={"query": "hi"}, headers=alice)
    assert r.status_code == 429
    assert await _ledger(db_session, uid, "ask") == 0  # refused before the user budget is touched
    r = await client.post(f"/v1/sessions/{b['id']}/ask", json={"query": "hi"}, headers=alice)
    assert r.status_code == 200
