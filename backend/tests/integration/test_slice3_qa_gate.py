"""Brief 005 QA gate (backend): concurrency, revision/event invariants, pinned versions, timers,
private variations and PRIV-02. Complements ``test_sessions_api`` / ``test_slice3_gate``."""

from __future__ import annotations

import asyncio
import uuid
from datetime import UTC, datetime, timedelta

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from tests.conftest import bearer, draft_payload
from tests.integration.slice3_helpers import (
    canon,
    command,
    ok,
    seed,
    set_prefs,
    start_session,
)
from tests.integration.test_publish import publish_new

GOCHU = "gochujang-chicken-thighs"
SALAD = "cucumber-salad"
SWAP = {"ingredient_ref": "ing-4", "replacement": "maple syrup", "source": "rule"}


async def _events(db: AsyncSession, session_id: str) -> list[tuple[int, str]]:
    await db.rollback()  # fresh snapshot
    rows = await db.execute(
        text("select sequence, type from session_events where session_id = :s order by sequence"),
        {"s": session_id},
    )
    return [(r[0], r[1]) for r in rows]


async def _assert_event_log_matches(db: AsyncSession, s: dict) -> None:
    """event sequence == revision: contiguous 0..revision, one event per revision."""
    log = await _events(db, s["id"])
    assert [seq for seq, _ in log] == list(range(s["revision"] + 1)), log


async def _active(client: AsyncClient, h: dict, version: str, adaptations=None) -> dict:
    s = await start_session(client, h, version, adaptations)
    return ok(await command(client, h, s, "start"))


async def _complete(client: AsyncClient, h: dict, s: dict, **outcome: object) -> dict:
    return ok(await command(client, h, s, "complete", outcome=outcome))


# ------------------------------------------------------------------ idempotency under concurrency


async def test_ten_parallel_identical_next_advance_once_with_identical_bodies(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await _active(client, alice, versions[GOCHU])
    rs = await asyncio.gather(
        *(command(client, alice, s, "next", key="same-key") for _ in range(10))
    )
    assert [r.status_code for r in rs] == [200] * 10, [r.text for r in rs if r.status_code != 200]
    assert len({r.content for r in rs}) == 1  # byte-identical
    assert rs[0].json()["step_index"] == 1 and rs[0].json()["revision"] == s["revision"] + 1
    now = ok(await client.get(f"/v1/sessions/{s['id']}", headers=alice))
    assert (now["step_index"], now["revision"]) == (1, s["revision"] + 1)
    await _assert_event_log_matches(db_session, now)


async def test_ten_parallel_same_key_different_bodies_one_wins_rest_409(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await _active(client, alice, versions[GOCHU])
    names = ["next", "pause", "complete", "abandon", "jump_to_step"] * 2
    rs = await asyncio.gather(
        *(
            command(
                client,
                alice,
                s,
                n,
                key="shared",
                **({"step_index": 3} if n == "jump_to_step" else {}),
            )
            for n in names
        )
    )
    winners = [r for r in rs if r.status_code == 200]
    assert {r.status_code for r in rs} <= {200, 409}
    # identical pairs (same body) replay the winner's response; different bodies conflict
    assert len(winners) == 2 and len({r.content for r in winners}) == 1
    losers = [r for r in rs if r.status_code == 409]
    assert len(losers) == 8
    assert all(r.json()["error"]["code"] == "STATE_CONFLICT" for r in losers)
    now = ok(await client.get(f"/v1/sessions/{s['id']}", headers=alice))
    assert now["revision"] == s["revision"] + 1  # exactly one state change
    await _assert_event_log_matches(db_session, now)


async def test_ten_parallel_distinct_keys_same_revision_one_200_nine_409(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await _active(client, alice, versions[GOCHU])
    rs = await asyncio.gather(*(command(client, alice, s, "next", key=f"k-{i}") for i in range(10)))
    codes = sorted(r.status_code for r in rs)
    assert codes == [200] + [409] * 9, codes
    for r in rs:
        if r.status_code == 409:
            err = r.json()["error"]
            assert err["code"] == "STATE_CONFLICT"
            assert err["details"]["session"]["revision"] == s["revision"] + 1
            assert err["details"]["session"]["id"] == s["id"]
    now = ok(await client.get(f"/v1/sessions/{s['id']}", headers=alice))
    assert (now["step_index"], now["revision"]) == (1, s["revision"] + 1)
    await _assert_event_log_matches(db_session, now)


async def test_replay_after_session_moved_on_returns_the_original_response(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await _active(client, alice, versions[GOCHU])
    first = await command(client, alice, s, "next", key="k1")
    moved = ok(await command(client, alice, first.json(), "next"))
    again = await command(client, alice, s, "next", key="k1")  # stale revision, same key + body
    assert again.status_code == 200 and again.content == first.content
    now = ok(await client.get(f"/v1/sessions/{s['id']}", headers=alice))
    assert now["step_index"] == moved["step_index"] == 2


# ------------------------------------------------------------------ revision semantics


async def test_every_change_bumps_exactly_once_and_noops_and_failures_do_not(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await start_session(client, alice, versions[GOCHU], [SWAP])
    rev = 0
    assert s["revision"] == 0
    await _assert_event_log_matches(db_session, s)

    async def step(name: str, *, bumps: bool = True, **extra: object) -> dict:
        nonlocal rev, s
        s = ok(await command(client, alice, s, name, **extra))
        rev += 1 if bumps else 0
        assert s["revision"] == rev, name
        await _assert_event_log_matches(db_session, s)
        return s

    async def rejected(name: str, code: int, **extra: object) -> None:
        r = await command(client, alice, s, name, **extra)
        assert r.status_code == code, (name, r.status_code, r.text)
        cur = ok(await client.get(f"/v1/sessions/{s['id']}", headers=alice))
        assert canon(cur) == canon(s), name  # nothing changed, including no partial side effect
        await _assert_event_log_matches(db_session, cur)

    await rejected("back", 409)  # created: not active
    await step("start")
    await step("back", bumps=False)  # boundary no-op
    await step("jump_to_step", bumps=False, step_index=0)  # jump to current: no-op
    await step("next")
    await step("jump_to_step", step_index=4)
    await step("back")
    await step("pause")
    # adaptations and timers are allowed while paused and bump exactly once each
    other = {"ingredient_ref": "ing-4", "replacement": "brown sugar + a splash of water"}
    await step("approve_adaptation", adaptation={**other, "source": "rule"})  # replaces maple
    assert [a["replacement"] for a in s["adaptations"]] == [other["replacement"]]
    assert s["step_index"] == 3 and s["status"] == "paused"
    await step("revert_adaptation", adaptation_id=s["adaptations"][0]["id"])
    assert s["adaptations"] == [] and all(not st["adapted"] for st in s["steps"])
    await step("start_timer", timer={"label": "Rest", "duration_seconds": 30})
    await step("cancel_timer", timer_id=s["timers"][0]["id"])
    await step("resume")
    # rejected commands leave revision, rows and events alone
    await rejected("jump_to_step", 422, step_index=99)
    await rejected("start_timer", 422, timer={"label": "x", "duration_seconds": 0})
    await rejected("cancel_timer", 404, timer_id=str(uuid.uuid4()))
    await rejected("revert_adaptation", 404, adaptation_id=str(uuid.uuid4()))
    await rejected("cancel_timer", 409, timer_id=s["timers"][0]["id"])  # already cancelled
    await rejected("next", 409, expected_revision=rev - 1)  # stale
    await rejected("start", 409)
    await rejected("next", 422, user_confirmed=False)
    await step("complete")
    for name in ("next", "pause", "abandon", "start_timer"):
        extra = {"timer": {"label": "x", "duration_seconds": 5}} if name == "start_timer" else {}
        await rejected(name, 409, **extra)
    types = [t for _, t in await _events(db_session, s["id"])]
    assert types[0] == "session_created" and types[-1] == "session_completed"
    assert len(types) == rev + 1


async def test_notes_do_not_bump_revision(client: AsyncClient, db_session: AsyncSession) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await _active(client, alice, versions[SALAD])
    r = await client.post(f"/v1/sessions/{s['id']}/notes", json={"text": "hi"}, headers=alice)
    assert r.status_code == 201
    now = ok(await client.get(f"/v1/sessions/{s['id']}", headers=alice))
    assert now["revision"] == s["revision"]
    await _assert_event_log_matches(db_session, now)


# ------------------------------------------------------------------ pinned version


async def test_creator_unpublishes_and_publishes_v2_v3_session_stays_byte_identical_v1(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await seed(db_session)
    creator = await bearer(client, "creator@example.com")
    learner = await bearer(client, "learner@example.com")
    stranger = await bearer(client, "stranger@example.com")
    v1 = await publish_new(client, creator)
    created = await start_session(client, learner, v1["recipe_version_id"])
    s = ok(await command(client, learner, created, "start"))
    assert canon(s["recipe"]) == canon(created["recipe"])

    unpublish = f"/v1/recipes/{v1['recipe_id']}/unpublish"
    assert (await client.post(unpublish, json={}, headers=creator)).status_code == 200
    for n in (2, 3):
        draft = (
            await client.post(f"/v1/recipes/{v1['recipe_id']}/edit", json={}, headers=creator)
        ).json()
        patch = await client.patch(
            f"/v1/recipes/drafts/{draft['id']}",
            json={
                "title": f"Changed {n}",
                "ingredients": [{"id": "ing-1", "name": f"other {n}", "quantity": 1, "unit": "g"}],
                "steps": [{"id": "step-1", "instruction": f"New {n}.", "ingredient_refs": []}],
                "creator_notes": [f"note {n}"],
            },
            headers=creator,
        )
        assert patch.status_code == 200, patch.text
        pub = await client.post(
            f"/v1/recipes/drafts/{draft['id']}/publish", json={}, headers=creator
        )
        assert pub.status_code == 201 and pub.json()["version_number"] == n, pub.text
        assert (await client.post(unpublish, json={}, headers=creator)).status_code == 200

    s2 = ok(await command(client, learner, s, "next"))
    again = ok(await client.get(f"/v1/sessions/{s['id']}", headers=learner))
    for view in (s2, again):
        assert canon(view["recipe"]) == canon(created["recipe"])
        assert view["recipe_version_id"] == v1["recipe_version_id"]
        assert view["steps_count"] == len(created["steps"])
        assert [st["original_instruction"] for st in view["steps"]] == [
            st["original_instruction"] for st in created["steps"]
        ]
    # the learner can still read v1 (and ask for swaps on it); a stranger cannot
    got = await client.get(f"/v1/recipe-versions/{v1['recipe_version_id']}", headers=learner)
    assert got.status_code == 200 and got.json()["version_number"] == 1
    suggest_body = {"recipe_version_id": v1["recipe_version_id"], "ingredient_ref": "ing-3"}
    sub = await client.post("/v1/substitutions/suggest", json=suggest_body, headers=learner)
    assert sub.status_code == 200, sub.text
    stranger_calls = (
        ("get", f"/v1/recipe-versions/{v1['recipe_version_id']}", None),
        ("post", "/v1/substitutions/suggest", suggest_body),
        ("post", "/v1/sessions", {"recipe_version_id": v1["recipe_version_id"]}),
    )
    for method, url, payload in stranger_calls:
        r = await client.request(method, url, json=payload, headers=stranger)
        assert r.status_code == 404, (method, url, r.text)
    done = ok(await command(client, learner, s2, "complete"))
    assert done["status"] == "completed"


# ------------------------------------------------------------------ timers


async def test_timer_target_is_server_clock_and_ignores_client_time(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await _active(client, alice, versions[SALAD])
    skew = (datetime.now(UTC) - timedelta(days=400)).isoformat()
    before = datetime.now(UTC)
    body = {
        "command": "start_timer",
        "expected_revision": s["revision"],
        "user_confirmed": True,
        "timer": {"label": "Rest", "duration_seconds": 120},
        "metadata": {"client_time": skew, "now": skew},
    }
    r = await client.post(
        f"/v1/sessions/{s['id']}/commands",
        json=body,
        headers={
            **alice,
            "Idempotency-Key": "t1",
            "Date": "Mon, 01 Jan 2001 00:00:00 GMT",
            "X-Client-Time": skew,
        },
    )
    s = ok(r)
    target = datetime.fromisoformat(s["timers"][0]["target_at"])
    assert timedelta(seconds=119) <= target - before <= timedelta(seconds=125)
    assert s["timers"][0]["status"] == "running"
    # a client-supplied absolute deadline is rejected outright
    bad = await client.post(
        f"/v1/sessions/{s['id']}/commands",
        json={
            **body,
            "expected_revision": s["revision"],
            "timer": {"label": "x", "duration_seconds": 5, "target_at": skew},
        },
        headers={**alice, "Idempotency-Key": "t2"},
    )
    assert bad.status_code == 422
    # replaying the same key later does not re-stamp target_at
    await asyncio.sleep(0.05)
    again = await client.post(
        f"/v1/sessions/{s['id']}/commands",
        json=body,
        headers={**alice, "Idempotency-Key": "t1"},
    )
    assert again.status_code == 200
    assert again.json()["timers"][0]["target_at"] == s["timers"][0]["target_at"]
    assert len(again.json()["timers"]) == 1


async def test_more_than_ten_running_timers_is_422_done_and_cancelled_do_not_count(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await _active(client, alice, versions[SALAD])
    for i in range(10):
        s = ok(
            await command(
                client, alice, s, "start_timer", timer={"label": f"T{i}", "duration_seconds": 600}
            )
        )
    assert sum(t["status"] == "running" for t in s["timers"]) == 10
    r = await command(
        client, alice, s, "start_timer", timer={"label": "11th", "duration_seconds": 60}
    )
    assert r.status_code == 422 and r.json()["error"]["code"] == "VALIDATION_ERROR"
    cur = ok(await client.get(f"/v1/sessions/{s['id']}", headers=alice))
    assert len(cur["timers"]) == 10 and cur["revision"] == s["revision"]
    # a finished (done-on-read) timer frees a slot ...
    await db_session.execute(
        text("update timers set target_at = now() - interval '1 second' where id = :t"),
        {"t": s["timers"][0]["id"]},
    )
    await db_session.commit()
    s = ok(
        await command(
            client, alice, cur, "start_timer", timer={"label": "11th", "duration_seconds": 60}
        )
    )
    assert sum(t["status"] == "running" for t in s["timers"]) == 10
    r = await command(
        client, alice, s, "start_timer", timer={"label": "12th", "duration_seconds": 5}
    )
    assert r.status_code == 422
    # ... and so does a cancelled one
    running = next(t for t in s["timers"] if t["status"] == "running")
    s = ok(await command(client, alice, s, "cancel_timer", timer_id=running["id"]))
    s = ok(
        await command(
            client, alice, s, "start_timer", timer={"label": "12th", "duration_seconds": 5}
        )
    )
    assert sum(t["status"] == "running" for t in s["timers"]) == 10
    await _assert_event_log_matches(db_session, s)


async def test_timers_never_start_without_a_command(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await _active(client, alice, versions[GOCHU])
    s = ok(await command(client, alice, s, "jump_to_step", step_index=1))
    assert s["steps"][1]["suggested_timer"] is not None  # offered ...
    assert s["timers"] == []  # ... never started
    r = await client.post(
        f"/v1/sessions/{s['id']}/ask", json={"query": "set a timer for 20 minutes"}, headers=alice
    )
    assert r.status_code == 200 and r.json()["proposed_action"]["command"] == "start_timer"
    cur = ok(await client.get(f"/v1/sessions/{s['id']}", headers=alice))
    assert cur["timers"] == [] and cur["revision"] == s["revision"]


# ------------------------------------------------------------------ private variation


async def test_variation_saved_only_on_complete_with_save_changes_and_active_swaps(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    url = f"/v1/recipe-versions/{versions[GOCHU]}/my-variation"

    s = await _active(client, alice, versions[GOCHU], [SWAP])
    s = await _complete(client, alice, s, result="cooked", save_changes=False)
    assert s["outcome"] == {"result": "cooked", "saved_changes": False}
    assert (await client.get(url, headers=alice)).status_code == 404
    s = await _active(client, alice, versions[GOCHU], [SWAP])  # complete without an outcome
    ok(await command(client, alice, s, "complete"))
    assert (await client.get(url, headers=alice)).status_code == 404
    s = await _active(client, alice, versions[GOCHU], [SWAP])  # abandon
    ok(await command(client, alice, s, "abandon"))
    assert (await client.get(url, headers=alice)).status_code == 404
    s = await _active(client, alice, versions[GOCHU], [SWAP])  # reverted -> no active swaps
    s = ok(
        await command(
            client, alice, s, "revert_adaptation", adaptation_id=s["adaptations"][0]["id"]
        )
    )
    s = await _complete(client, alice, s, result="cooked", save_changes=True)
    assert s["outcome"]["saved_changes"] is False
    assert (await client.get(url, headers=alice)).status_code == 404
    s = await _active(client, alice, versions[GOCHU])  # swap approved mid-session, saved
    s = ok(await command(client, alice, s, "approve_adaptation", adaptation={**SWAP}))
    s = await _complete(client, alice, s, result="cooked", save_changes=True)
    assert s["outcome"]["saved_changes"] is True
    got = ok(await client.get(url, headers=alice))
    assert [a["replacement"] for a in got["adaptations"]] == ["maple syrup"]
    assert set(got["adaptations"][0]) == {
        "id",
        "ingredient_ref",
        "original",
        "replacement",
        "ratio_or_amount",
        "source",
        "label",
        "reason",
        "approved_at",
        # fix round 1 (items 13 + 17a): additive Session adaptation fields
        "allergy_warning",
        "risks",
        "conflicts_with_allergies",
    }
    s = await _active(  # the next save replaces, never merges
        client,
        alice,
        versions[GOCHU],
        [{"ingredient_ref": "ing-9", "replacement": "light olive oil", "source": "rule"}],
    )
    await _complete(client, alice, s, result="partly", save_changes=True)
    got = ok(await client.get(url, headers=alice))
    assert [a["ingredient_ref"] for a in got["adaptations"]] == ["ing-9"]
    assert (await client.delete(url, headers=alice)).status_code == 204
    assert (await client.get(url, headers=alice)).status_code == 404


async def test_variation_is_filtered_when_the_recipe_changes_and_rechecked_for_allergies(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await seed(db_session)
    creator = await bearer(client, "creator@example.com")
    v1 = await publish_new(client, creator)
    swap = {"ingredient_ref": "ing-3", "replacement": "olive oil", "source": "ai"}
    s = await _active(client, creator, v1["recipe_version_id"], [swap])
    await _complete(client, creator, s, result="cooked", save_changes=True)

    async def republish(ingredients: list[dict], **more: object) -> str:
        draft = (
            await client.post(f"/v1/recipes/{v1['recipe_id']}/edit", json={}, headers=creator)
        ).json()
        patched = await client.patch(
            f"/v1/recipes/drafts/{draft['id']}",
            json={"ingredients": ingredients, **more},
            headers=creator,
        )
        assert patched.status_code == 200, patched.text
        r = await client.post(f"/v1/recipes/drafts/{draft['id']}/publish", json={}, headers=creator)
        assert r.status_code == 201, r.text
        return r.json()["recipe_version_id"]

    base = draft_payload()["ingredients"]
    same = await republish(base)  # unchanged ingredients: still applies to v2
    got = ok(await client.get(f"/v1/recipe-versions/{same}/my-variation", headers=creator))
    assert [a["replacement"] for a in got["adaptations"]] == ["olive oil"]
    renamed = [dict(i) for i in base]
    renamed[2] = {**renamed[2], "name": "ghee"}  # ing-3 is no longer butter
    v3 = await republish(renamed)
    assert (
        await client.get(f"/v1/recipe-versions/{v3}/my-variation", headers=creator)
    ).status_code == 404
    steps = [dict(st) for st in draft_payload()["steps"]]
    steps[1]["ingredient_refs"] = ["ing-2"]
    v4 = await republish([i for i in base if i["id"] != "ing-3"], steps=steps)  # ing-3 removed
    assert (
        await client.get(f"/v1/recipe-versions/{v4}/my-variation", headers=creator)
    ).status_code == 404
    # an allergy added after saving: the same swap is refused when sent back to POST /sessions
    await set_prefs(client, creator, ["olive"])
    r = await client.post(
        "/v1/sessions", json={"recipe_version_id": same, "adaptations": [swap]}, headers=creator
    )
    assert r.status_code == 422


# ------------------------------------------------------------------ PRIV-02


async def test_delete_removes_session_data_but_keeps_usage_ledger_and_saved_variation(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    uid = await db_session.scalar(text("select id from users where email = 'alice@example.com'"))
    s = await _active(client, alice, versions[GOCHU], [SWAP])
    s = ok(
        await command(
            client, alice, s, "start_timer", timer={"label": "Rest", "duration_seconds": 60}
        )
    )
    await client.post(f"/v1/sessions/{s['id']}/notes", json={"text": "salty"}, headers=alice)
    for q in ("what now?", "how much soy sauce?"):
        r = await client.post(f"/v1/sessions/{s['id']}/ask", json={"query": q}, headers=alice)
        assert r.status_code == 200
    s = await _complete(client, alice, s, result="cooked", save_changes=True)
    tables = (
        "session_events",
        "session_messages",
        "timers",
        "session_notes",
        "session_adaptations",
    )

    async def counts() -> dict[str, int]:
        await db_session.rollback()
        out: dict[str, int] = {}
        for table in tables:
            out[table] = int(
                await db_session.scalar(
                    text(f"select count(*) from {table} where session_id = :s"), {"s": s["id"]}
                )
                or 0
            )
        for kind in ("ask", "session_created"):
            out[kind] = int(
                await db_session.scalar(
                    text("select count(*) from usage_events where user_id = :u and kind = :k"),
                    {"u": uid, "k": kind},
                )
                or 0
            )
        return out

    before = await counts()
    assert all(v > 0 for v in before.values()), before
    assert before["ask"] == 2 and before["session_created"] == 1
    assert (await client.delete(f"/v1/sessions/{s['id']}", headers=alice)).status_code == 204
    after = await counts()
    for table in tables:
        assert after[table] == 0, (table, after)
    assert (after["ask"], after["session_created"]) == (2, 1)  # budget not reset
    # the saved private variation is the user's own data and survives
    url = f"/v1/recipe-versions/{versions[GOCHU]}/my-variation"
    assert (await client.get(url, headers=alice)).status_code == 200
    assert (await client.delete(f"/v1/sessions/{s['id']}", headers=alice)).status_code == 404
