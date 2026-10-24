"""Brief 005 gate: full cook with an accepted substitution, relaunch recovery, idempotent Next,
v2 published mid-session, private variations, pinned-version access (PRD §17.2 5/7/8)."""

from __future__ import annotations

from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.db.models import SessionEvent
from app.main import create_app
from tests.conftest import bearer
from tests.integration.slice3_helpers import (
    canon,
    command,
    ok,
    seed,
    set_prefs,
    start_session,
    suggest,
)
from tests.integration.test_publish import publish_new

GOCHU = "gochujang-chicken-thighs"


async def test_full_recipe_with_accepted_substitution(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    pinned = ok(await client.get(f"/v1/recipe-versions/{versions[GOCHU]}", headers=alice))
    offer = await suggest(client, alice, versions[GOCHU], "ing-4")  # honey
    maple = next(s for s in offer["suggestions"] if s["candidate"] == "maple syrup")
    s = await start_session(
        client,
        alice,
        versions[GOCHU],
        [{"ingredient_ref": "ing-4", "suggestion_id": maple["suggestion_id"]}],
    )
    (adaptation,) = s["adaptations"]
    assert adaptation["replacement"] == "maple syrup" and adaptation["label"] == "Common swap"
    assert adaptation["original"] == "honey" and adaptation["source"] == "rule"
    assert adaptation["reason"] == "honey unavailable" and adaptation["approved_at"]
    marinade = s["steps"][0]
    assert marinade["adapted"] is True and marinade["adaptation_ids"] == [adaptation["id"]]
    assert "maple syrup" in marinade["instruction"] and "honey" not in marinade["instruction"]
    assert "honey" in marinade["original_instruction"]
    # The pinned recipe itself is never mutated.
    assert canon(s["recipe"]["steps"]) == canon(pinned["steps"])

    s = ok(await command(client, alice, s, "start"))
    for expected in range(1, 7):
        s = ok(await command(client, alice, s, "next"))
        assert s["step_index"] == expected
    s = ok(
        await command(
            client, alice, s, "complete", outcome={"result": "cooked", "save_changes": True}
        )
    )
    assert s["status"] == "completed" and s["outcome"] == {
        "result": "cooked",
        "saved_changes": True,
    }
    assert s["revision"] == 8
    events = await db_session.scalar(select(func.count()).select_from(SessionEvent))
    assert events == 9  # created + start + 6 next + complete

    variation = ok(
        await client.get(f"/v1/recipe-versions/{versions[GOCHU]}/my-variation", headers=alice)
    )
    assert [a["replacement"] for a in variation["adaptations"]] == ["maple syrup"]
    again = await start_session(
        client,
        alice,
        versions[GOCHU],
        [
            {
                k: a[k]
                for k in ("ingredient_ref", "replacement", "ratio_or_amount", "source", "reason")
            }
            for a in variation["adaptations"]
        ],
    )
    assert again["adaptations"][0]["replacement"] == "maple syrup"
    assert again["steps"][0]["instruction"] == marinade["instruction"]
    assert (
        await client.delete(f"/v1/recipe-versions/{versions[GOCHU]}/my-variation", headers=alice)
    ).status_code == 204
    assert (
        await client.get(f"/v1/recipe-versions/{versions[GOCHU]}/my-variation", headers=alice)
    ).status_code == 404


async def test_approve_and_revert_mid_session(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = ok(
        await command(client, alice, await start_session(client, alice, versions[GOCHU]), "start")
    )
    s = ok(await command(client, alice, s, "next"))
    offer = await suggest(client, alice, versions[GOCHU], "ing-1")  # chicken thighs
    breast = offer["suggestions"][0]
    assert breast["candidate"].startswith("chicken breast")
    assert any("165°F" in r for r in breast["risks"])  # food-safety guidance attached
    s2 = ok(
        await command(
            client,
            alice,
            s,
            "approve_adaptation",
            adaptation={"ingredient_ref": "ing-1", "suggestion_id": breast["suggestion_id"]},
        )
    )
    assert s2["revision"] == s["revision"] + 1 and s2["step_index"] == s["step_index"]
    adapted = {st["step_id"]: st for st in s2["steps"] if st["adapted"]}
    # Tagged steps 2/4/5 are rewritten; untagged mentions (steps 1 and 6) are only annotated.
    assert set(adapted) == {"step-1", "step-2", "step-4", "step-5", "step-6"}
    assert "(Swap: use chicken breast" in adapted["step-6"]["instruction"]
    assert "chicken breast" in adapted["step-2"]["instruction"]
    assert s2["adaptations"][0]["label"] == "Common swap"
    s3 = ok(
        await command(
            client, alice, s2, "revert_adaptation", adaptation_id=s2["adaptations"][0]["id"]
        )
    )
    assert s3["adaptations"] == [] and not any(st["adapted"] for st in s3["steps"])
    assert [st["instruction"] for st in s3["steps"]] == [
        st["original_instruction"] for st in s3["steps"]
    ]
    assert s3["step_index"] == s["step_index"]
    r = await command(
        client, alice, s3, "revert_adaptation", adaptation_id=s2["adaptations"][0]["id"]
    )
    assert r.status_code == 409
    # An AI-labelled explicit swap; then a second swap for the same ingredient replaces it.
    s4 = ok(
        await command(
            client,
            alice,
            s3,
            "approve_adaptation",
            adaptation={"ingredient_ref": "ing-4", "replacement": "agave syrup", "source": "ai"},
        )
    )
    assert s4["adaptations"][0]["label"] == "AI suggested adaptation"
    s5 = ok(
        await command(
            client,
            alice,
            s4,
            "approve_adaptation",
            adaptation={"ingredient_ref": "ing-4", "replacement": "maple syrup", "source": "rule"},
        )
    )
    assert [a["replacement"] for a in s5["adaptations"]] == ["maple syrup"]
    r = await command(client, alice, s5, "approve_adaptation")
    assert r.status_code == 422


async def test_allergies_rechecked_at_approval(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    offer = await suggest(client, alice, versions[GOCHU], "ing-9")
    peanut = next(s for s in offer["suggestions"] if s["candidate"] == "peanut oil")
    await set_prefs(client, alice, ["peanuts"])
    r = await client.post(
        "/v1/sessions",
        json={
            "recipe_version_id": versions[GOCHU],
            "adaptations": [{"ingredient_ref": "ing-9", "suggestion_id": peanut["suggestion_id"]}],
        },
        headers=alice,
    )
    assert r.status_code == 422 and "allergy" in r.json()["error"]["message"]
    s = await start_session(client, alice, versions[GOCHU])
    r = await command(
        client,
        alice,
        s,
        "approve_adaptation",
        adaptation={"ingredient_ref": "ing-9", "replacement": "peanut oil", "source": "ai"},
    )
    assert r.status_code == 422
    bob = await bearer(client, "bob@example.com")  # someone else's suggestion id is unknown
    r = await client.post(
        "/v1/sessions",
        json={
            "recipe_version_id": versions[GOCHU],
            "adaptations": [{"ingredient_ref": "ing-9", "suggestion_id": peanut["suggestion_id"]}],
        },
        headers=bob,
    )
    assert r.status_code == 422


async def test_relaunch_recovery_restores_step_overlay_and_timers(
    client: AsyncClient, db_session: AsyncSession, settings: Settings
) -> None:
    """PRD §17.2 scenario 7 / COOK-07: kill the app, relaunch, same state."""
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await start_session(
        client,
        alice,
        versions[GOCHU],
        [{"ingredient_ref": "ing-4", "replacement": "maple syrup", "source": "rule"}],
    )
    s = ok(await command(client, alice, s, "start"))
    s = ok(await command(client, alice, s, "next"))
    s = ok(
        await command(
            client, alice, s, "start_timer", timer={"label": "Rest", "duration_seconds": 1200}
        )
    )
    s = ok(await command(client, alice, s, "pause"))

    fresh = create_app(settings)  # a different process, same database
    async with fresh.router.lifespan_context(fresh):
        transport = ASGITransport(app=fresh, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as relaunched:
            banner = ok(await relaunched.get("/v1/sessions?status=active", headers=alice))["items"]
            assert [b["id"] for b in banner] == [s["id"]] and banner[0]["step_index"] == 1
            restored = ok(await relaunched.get(f"/v1/sessions/{s['id']}", headers=alice))
    assert restored["step_index"] == 1 and restored["status"] == "paused"
    assert restored["revision"] == s["revision"]
    assert restored["adaptations"] == s["adaptations"]
    assert restored["steps"] == s["steps"]
    assert restored["timers"] == s["timers"] and restored["timers"][0]["status"] == "running"


async def test_v2_published_mid_session_keeps_v1(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """PRD §17.2 scenario 5: the session recipe stays v1, byte-identical."""
    await seed(db_session)
    creator = await bearer(client, "creator@example.com")
    learner = await bearer(client, "learner@example.com")
    v1 = await publish_new(client, creator)
    s = ok(
        await command(
            client, learner, await start_session(client, learner, v1["recipe_version_id"]), "start"
        )
    )
    before = ok(await client.get(f"/v1/sessions/{s['id']}", headers=learner))

    draft = (
        await client.post(f"/v1/recipes/{v1['recipe_id']}/edit", json={}, headers=creator)
    ).json()
    await client.patch(
        f"/v1/recipes/drafts/{draft['id']}",
        json={
            "title": "Changed",
            "steps": [{"id": "step-9", "instruction": "New.", "ingredient_refs": []}],
        },
        headers=creator,
    )
    v2 = await client.post(f"/v1/recipes/drafts/{draft['id']}/publish", json={}, headers=creator)
    assert v2.status_code == 201 and v2.json()["version_number"] == 2

    after = ok(await command(client, learner, before, "next"))
    assert canon(after["recipe"]) == canon(before["recipe"])
    assert (
        after["recipe"]["version_number"] == 1
        and after["recipe_version_id"] == v1["recipe_version_id"]
    )
    assert [st["original_instruction"] for st in after["steps"]] == [
        st["instruction"] for st in before["recipe"]["steps"]
    ]
    latest = ok(await client.get(f"/v1/recipes/{v1['recipe_id']}", headers=learner))
    assert latest["version_number"] == 2

    # Unpublished later: the learner still reads the pinned version through the session.
    await client.post(f"/v1/recipes/{v1['recipe_id']}/unpublish", json={}, headers=creator)
    assert (
        await client.get(f"/v1/recipe-versions/{v1['recipe_version_id']}", headers=learner)
    ).status_code == 200
    stranger = await bearer(client, "stranger@example.com")
    assert (
        await client.get(f"/v1/recipe-versions/{v1['recipe_version_id']}", headers=stranger)
    ).status_code == 404
    assert (
        ok(await client.get(f"/v1/sessions/{s['id']}", headers=learner))["recipe"]["title"]
        == before["recipe"]["title"]
    )


async def test_variation_replaced_and_filtered(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    url = f"/v1/recipe-versions/{versions[GOCHU]}/my-variation"
    assert (await client.get(url, headers=alice)).status_code == 404
    for swap in ("maple syrup", "brown sugar + a splash of water"):
        s = await start_session(
            client,
            alice,
            versions[GOCHU],
            [{"ingredient_ref": "ing-4", "replacement": swap, "source": "rule"}],
        )
        s = ok(await command(client, alice, s, "start"))
        ok(
            await command(
                client, alice, s, "complete", outcome={"result": "partly", "save_changes": True}
            )
        )
    assert [a["replacement"] for a in ok(await client.get(url, headers=alice))["adaptations"]] == [
        "brown sugar + a splash of water"
    ]
    # Completing without swaps does not wipe the saved variation.
    s = ok(
        await command(client, alice, await start_session(client, alice, versions[GOCHU]), "start")
    )
    s = ok(
        await command(
            client, alice, s, "complete", outcome={"result": "cooked", "save_changes": True}
        )
    )
    assert s["outcome"] == {"result": "cooked", "saved_changes": False}
    assert (await client.get(url, headers=alice)).status_code == 200
    bob = await bearer(client, "bob@example.com")
    assert (await client.get(url, headers=bob)).status_code == 404


async def test_uppercase_uuids_and_rice_vinegar_smoke_path(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """iOS sends uppercase UUIDs in bodies and paths; the live smoke swaps rice vinegar (ing-8)."""
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    v = versions[GOCHU].upper()
    offer = await suggest(client, alice, v, "ing-8")
    assert offer["suggestions"], "the smoke needs at least one rice vinegar suggestion"
    first = offer["suggestions"][0]
    assert "step-1" in {a["step_id"] for a in first["adjusted_steps"]}
    s = await start_session(client, alice, v)
    sid = s["id"].upper()
    upper = {**s, "id": sid}
    s = ok(await command(client, alice, upper, "start"))
    s = ok(
        await command(
            client,
            alice,
            {**s, "id": sid},
            "approve_adaptation",
            adaptation={"ingredient_ref": "ing-8", "suggestion_id": first["suggestion_id"].upper()},
        )
    )
    assert s["steps"][0]["adapted"] is True  # the "adapted" badge on the marinade step
    adaptation_id = s["adaptations"][0]["id"]
    s = ok(
        await command(
            client,
            alice,
            {**s, "id": sid},
            "start_timer",
            timer={"label": "x", "duration_seconds": 5},
        )
    )
    timer_id = s["timers"][0]["id"]
    s = ok(
        await command(client, alice, {**s, "id": sid}, "cancel_timer", timer_id=timer_id.upper())
    )
    s = ok(
        await command(
            client,
            alice,
            {**s, "id": sid},
            "revert_adaptation",
            adaptation_id=adaptation_id.upper(),
        )
    )
    assert s["adaptations"] == [] and s["timers"][0]["status"] == "cancelled"
    assert (await client.get(f"/v1/sessions/{sid}", headers=alice)).status_code == 200
    assert (await client.get(f"/v1/recipe-versions/{v}", headers=alice)).status_code == 200


async def test_variation_uses_the_session_adaptation_shape(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await start_session(
        client,
        alice,
        versions[GOCHU],
        [{"ingredient_ref": "ing-4", "replacement": "maple syrup", "source": "rule"}],
    )
    s = ok(await command(client, alice, s, "start"))
    s = ok(
        await command(
            client, alice, s, "complete", outcome={"result": "cooked", "save_changes": True}
        )
    )
    url = f"/v1/recipe-versions/{versions[GOCHU]}/my-variation"
    (saved,) = ok(await client.get(url, headers=alice))["adaptations"]
    assert (
        saved == s["adaptations"][0]
    )  # {id, ingredient_ref, original, replacement, ..., approved_at}
    reuse = {
        k: saved[k]
        for k in ("ingredient_ref", "replacement", "ratio_or_amount", "source", "reason")
    }
    again = await start_session(client, alice, versions[GOCHU], [reuse])
    assert again["adaptations"][0]["label"] == "Common swap"
