"""Brief 005: sessions — create/pin, read, list, delete, notes and the command contract."""

from __future__ import annotations

import asyncio
import uuid
from datetime import UTC, datetime, timedelta

from httpx import AsyncClient
from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import SessionEvent
from tests.conftest import bearer
from tests.integration.slice3_helpers import command, ok, seed, start_session

GOCHU = "gochujang-chicken-thighs"
SALAD = "cucumber-salad"


async def _events(db: AsyncSession, session_id: str) -> int:
    return int(
        await db.scalar(
            select(func.count())
            .select_from(SessionEvent)
            .where(SessionEvent.session_id == uuid.UUID(session_id))
        )
        or 0
    )


async def test_create_pins_version_step0_and_pantry_snapshot(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    await client.post(
        "/v1/pantry",
        json={
            "items": [
                {"raw_label": "gochujang", "source": "manual"},
                {"raw_label": "chocolate", "source": "manual"},
            ]
        },
        headers=alice,
    )
    s = await start_session(client, alice, versions[GOCHU])
    assert s["status"] == "created" and s["revision"] == 0 and s["step_index"] == 0
    assert s["recipe_version_id"] == versions[GOCHU]
    assert s["recipe"]["recipe_version_id"] == versions[GOCHU]
    assert s["steps_count"] == len(s["recipe"]["steps"]) == len(s["steps"]) == 7
    # Only the relevant pantry subset, never the whole kitchen.
    assert [p["normalized_name"] for p in s["pantry_snapshot"]] == ["gochujang"]
    assert s["adaptations"] == [] and s["timers"] == [] and s["notes"] == []
    assert s["outcome"] is None and s["started_at"] is None
    marinate = s["steps"][1]
    assert marinate["suggested_timer"] == {"label": "Rest", "duration_seconds": 1200}
    assert marinate["adapted"] is False
    assert marinate["instruction"] == marinate["original_instruction"]


async def test_create_validates_version_and_refs(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    r = await client.post(
        "/v1/sessions", json={"recipe_version_id": str(uuid.uuid4())}, headers=alice
    )
    assert r.status_code == 404
    bad = {"ingredient_ref": "ing-99", "replacement": "x", "source": "ai"}
    r = await client.post(
        "/v1/sessions",
        json={"recipe_version_id": versions[GOCHU], "adaptations": [bad]},
        headers=alice,
    )
    assert r.status_code == 422
    dup = {"ingredient_ref": "ing-4", "replacement": "maple syrup", "source": "rule"}
    r = await client.post(
        "/v1/sessions",
        json={"recipe_version_id": versions[GOCHU], "adaptations": [dup, dup]},
        headers=alice,
    )
    assert r.status_code == 422


async def test_progression_boundaries_and_events(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await start_session(client, alice, versions[SALAD])
    assert (await command(client, alice, s, "next")).status_code == 409  # not started
    s = ok(await command(client, alice, s, "start"))
    assert s["status"] == "active" and s["revision"] == 1 and s["started_at"]
    before = await _events(db_session, s["id"])
    same = ok(await command(client, alice, s, "back"))  # boundary no-op at step 0
    assert same["revision"] == 1 and same["step_index"] == 0
    assert await _events(db_session, s["id"]) == before
    s = ok(await command(client, alice, s, "next"))
    assert (s["step_index"], s["revision"]) == (1, 2)
    s = ok(await command(client, alice, s, "jump_to_step", step_index=5))
    assert s["step_index"] == 5
    noop = ok(await command(client, alice, s, "jump_to_step", step_index=5))
    assert noop["revision"] == s["revision"]
    r = await command(client, alice, s, "jump_to_step", step_index=9)
    assert r.status_code == 422
    r = await command(client, alice, s, "next")  # last step: complete explicitly
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "INVALID_TRANSITION"
    assert r.json()["error"]["details"]["session"]["revision"] == s["revision"]
    s = ok(await command(client, alice, s, "pause"))
    assert s["status"] == "paused" and s["step_index"] == 5
    s = ok(await command(client, alice, s, "resume"))
    s = ok(await command(client, alice, s, "complete"))
    assert s["status"] == "completed" and s["ended_at"]
    r = await command(client, alice, s, "back")
    assert r.status_code == 409 and r.json()["error"]["code"] == "INVALID_TRANSITION"


async def test_confirmation_key_and_revision_rules(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await start_session(client, alice, versions[SALAD])
    for value in (False, "true", 1, None):
        r = await command(client, alice, s, "start", user_confirmed=value)
        assert r.status_code == 422, value
        assert r.json()["error"]["code"] == "CONFIRMATION_REQUIRED"
    r = await client.post(
        f"/v1/sessions/{s['id']}/commands",
        json={"command": "start", "expected_revision": 0, "user_confirmed": True},
        headers=alice,
    )
    assert r.status_code == 422 and r.json()["error"]["code"] == "VALIDATION_ERROR"
    s1 = ok(await command(client, alice, s, "start"))
    r = await command(client, alice, s1, "next", expected_revision=0)
    assert r.status_code == 409
    err = r.json()["error"]
    assert err["code"] == "STATE_CONFLICT"
    assert err["details"]["session"]["revision"] == 1
    assert err["details"]["session"]["step_index"] == 0


async def test_same_idempotency_key_replays_and_mismatch_conflicts(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """PRD §17.2 scenario 8: repeat Next with the same key advances only once."""
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = ok(
        await command(client, alice, await start_session(client, alice, versions[SALAD]), "start")
    )
    key = "retry-next-1"
    first = await command(client, alice, s, "next", key=key)
    second = await command(client, alice, s, "next", key=key)
    assert first.status_code == second.status_code == 200
    assert first.content == second.content  # identical body, byte for byte
    assert first.json()["step_index"] == 1
    events = await _events(db_session, s["id"])
    assert events == 3  # created, started, one advance
    current = ok(await client.get(f"/v1/sessions/{s['id']}", headers=alice))
    assert current["step_index"] == 1 and current["revision"] == 2
    r = await command(client, alice, s, "back", key=key)  # same key, different body
    assert r.status_code == 409 and r.json()["error"]["code"] == "STATE_CONFLICT"
    assert r.json()["error"]["details"]["session"]["revision"] == 2
    assert await _events(db_session, s["id"]) == events


async def test_concurrent_commands_one_wins(client: AsyncClient, db_session: AsyncSession) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = ok(
        await command(client, alice, await start_session(client, alice, versions[SALAD]), "start")
    )
    a, b = await asyncio.gather(
        command(client, alice, s, "next", key="k-a"), command(client, alice, s, "next", key="k-b")
    )
    assert sorted([a.status_code, b.status_code]) == [200, 409]
    current = ok(await client.get(f"/v1/sessions/{s['id']}", headers=alice))
    assert current["step_index"] == 1 and current["revision"] == 2
    c, d = await asyncio.gather(
        command(client, alice, current, "next", key="k-same"),
        command(client, alice, current, "next", key="k-same"),
    )
    assert c.status_code == d.status_code == 200 and c.content == d.content
    after = ok(await client.get(f"/v1/sessions/{s['id']}", headers=alice))
    assert after["step_index"] == 2 and after["revision"] == 3


async def test_owner_only_everything_404(client: AsyncClient, db_session: AsyncSession) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    bob = await bearer(client, "bob@example.com")
    s = await start_session(client, alice, versions[SALAD])
    missing = {**s, "id": str(uuid.uuid4())}
    for target in (s, missing):
        sid = target["id"]
        responses = [
            await client.get(f"/v1/sessions/{sid}", headers=bob),
            await command(client, bob, target, "start"),
            await client.post(f"/v1/sessions/{sid}/ask", json={"query": "hi"}, headers=bob),
            await client.post(f"/v1/sessions/{sid}/notes", json={"text": "x"}, headers=bob),
            await client.delete(f"/v1/sessions/{sid}", headers=bob),
        ]
        assert [r.status_code for r in responses] == [404] * 5
        assert {r.json()["error"]["message"] for r in responses} == {"Session not found"}
    assert (await client.get("/v1/sessions/not-a-uuid", headers=alice)).status_code == 404
    assert (await client.get(f"/v1/sessions/{s['id']}", headers=alice)).status_code == 200


async def test_list_active_newest_first_and_delete_cascades(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    first = await start_session(client, alice, versions[SALAD])
    second = await start_session(client, alice, versions[GOCHU])
    done = ok(
        await command(client, alice, await start_session(client, alice, versions[SALAD]), "abandon")
    )
    listed = ok(await client.get("/v1/sessions?status=active", headers=alice))["items"]
    assert [i["id"] for i in listed] == [second["id"], first["id"]]
    assert listed[0]["title"] == "Gochujang Chicken Thighs" and listed[0]["steps_count"] == 7
    everything = ok(await client.get("/v1/sessions", headers=alice))["items"]
    assert done["id"] in {i["id"] for i in everything}
    bob = await bearer(client, "bob@example.com")
    assert ok(await client.get("/v1/sessions?status=active", headers=bob))["items"] == []
    assert (await client.get("/v1/sessions?status=bogus", headers=alice)).status_code == 422

    s = ok(await command(client, alice, second, "start"))
    s = ok(
        await command(
            client, alice, s, "start_timer", timer={"label": "Rest", "duration_seconds": 60}
        )
    )
    await client.post(f"/v1/sessions/{s['id']}/notes", json={"text": "too salty"}, headers=alice)
    await client.post(f"/v1/sessions/{s['id']}/ask", json={"query": "what now?"}, headers=alice)
    assert (await client.delete(f"/v1/sessions/{s['id']}", headers=alice)).status_code == 204
    assert (await client.get(f"/v1/sessions/{s['id']}", headers=alice)).status_code == 404
    for table in ("session_events", "session_messages", "timers", "session_notes"):
        n = await db_session.scalar(
            text(f"select count(*) from {table} where session_id = :s"), {"s": s["id"]}
        )
        assert n == 0, table


async def test_timers_absolute_target_done_on_read_and_cancel(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = ok(
        await command(client, alice, await start_session(client, alice, versions[SALAD]), "start")
    )
    s = ok(await command(client, alice, s, "next"))
    before = datetime.now(UTC)
    s = ok(
        await command(
            client, alice, s, "start_timer", timer={"label": "Drain", "duration_seconds": 600}
        )
    )
    assert s["step_index"] == 1 and s["revision"] == 3
    (timer,) = s["timers"]
    target = datetime.fromisoformat(timer["target_at"])
    assert timedelta(seconds=599) <= target - before <= timedelta(seconds=605)
    assert timer["status"] == "running" and timer["step_index"] == 1
    for bad in (0, 24 * 3600 + 1):
        r = await command(
            client, alice, s, "start_timer", timer={"label": "x", "duration_seconds": bad}
        )
        assert r.status_code == 422
    await db_session.execute(
        text("update timers set target_at = now() - interval '1 second' where id = :t"),
        {"t": timer["id"]},
    )
    await db_session.commit()
    s = ok(await client.get(f"/v1/sessions/{s['id']}", headers=alice))
    assert s["timers"][0]["status"] == "done"
    s = ok(await command(client, alice, s, "cancel_timer", timer_id=timer["id"]))
    assert s["timers"][0]["status"] == "cancelled" and s["step_index"] == 1
    r = await command(client, alice, s, "cancel_timer", timer_id=timer["id"])
    assert r.status_code == 409
    r = await command(client, alice, s, "cancel_timer", timer_id=str(uuid.uuid4()))
    assert r.status_code == 404


async def test_notes_on_finished_session(client: AsyncClient, db_session: AsyncSession) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = ok(
        await command(client, alice, await start_session(client, alice, versions[SALAD]), "abandon")
    )
    r = await client.post(
        f"/v1/sessions/{s['id']}/notes", json={"text": "  Next time less salt.  "}, headers=alice
    )
    assert r.status_code == 201 and r.json()["text"] == "Next time less salt."
    r = await client.post(f"/v1/sessions/{s['id']}/notes", json={"text": "x" * 1001}, headers=alice)
    assert r.status_code == 422
    got = ok(await client.get(f"/v1/sessions/{s['id']}", headers=alice))
    assert [n["text"] for n in got["notes"]] == ["Next time less salt."]
