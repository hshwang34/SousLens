"""Brief 005 fix round 1 (items 1-18): one test per behaviour the reviewers asked for."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from httpx import AsyncClient
from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.providers.base import CoachRequest, CoachResponse, ProposedAction
from app.db.models import (
    RecipeVersion,
    SessionNote,
    SubstitutionSuggestionRecord,
    UsageEvent,
    User,
)
from app.scripts.seed import seed_fixtures, seed_recipe
from tests.conftest import FIXTURES_DIR, bearer
from tests.integration.slice3_helpers import command, ok, seed, set_prefs, start_session, suggest
from tests.integration.test_publish import publish_new

GOCHU = "gochujang-chicken-thighs"
SALAD = "cucumber-salad"

PEANUT_OIL = (
    "Contains peanut. Refined peanut oil is lower-risk, but "
    "cold-pressed is not. Do not use with any peanut allergy."
)
RICE_HOLD = (
    "Cooked rice must not sit at room temperature more than 1 hour. Use "
    "it straight away, or chill within 1 hour and reheat until piping hot."
)
BREAST = (
    "Cooks faster and dries out. Still cook to 165°F (74°C) on an "
    "instant-read thermometer; time alone does not show it is done."
)
NO_PRESERVE = (
    "Do not use in pickling, canning or any preserved "
    "recipe: acidity differs and lemon juice is not standardised."
)


class Coach:
    def __init__(self, respond) -> None:  # type: ignore[no-untyped-def]
        self.respond = respond
        self.calls = 0

    async def answer(self, request: CoachRequest):  # type: ignore[no-untyped-def]
        self.calls += 1
        return await self.respond(request) if callable(self.respond) else self.respond


def use(client: AsyncClient, coach: object) -> None:
    client._transport.app.state.ai_provider = coach  # type: ignore[attr-defined]


async def active(client: AsyncClient, h: dict[str, str], v: str, **kw) -> dict:  # type: ignore[no-untyped-def]
    return ok(await command(client, h, await start_session(client, h, v, **kw), "start"))


async def _user(db: AsyncSession, email: str) -> User:
    return (await db.execute(select(User).where(User.email == email))).scalar_one()


# ------------------------------------------------------------------ items 1, 2, 6, 15 (ask)


@pytest.mark.parametrize(
    "query",
    [
        "Is the chicken ready?",
        "Can I eat it yet?",
        "Can I take the pork off the heat?",
        "did I cook it long enough",
        "medium rare yet?",
        "is it good to go",
    ],
)
async def test_doneness_is_a_fixed_template_and_the_model_is_not_called(
    client: AsyncClient, db_session: AsyncSession, query: str
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await active(client, alice, versions[GOCHU])
    s = ok(await command(client, alice, s, "jump_to_step", step_index=4))

    async def certify(req: CoachRequest) -> CoachResponse:
        return CoachResponse(
            answer_text="Yes! It is perfectly safe to eat.",
            grounded_session_revision=req.session_revision,
        )

    coach = Coach(certify)
    use(client, coach)
    r = ok(await client.post(f"/v1/sessions/{s['id']}/ask", json={"query": query}, headers=alice))
    assert coach.calls == 0
    assert r["answer_text"].startswith("The recipe says (step 5): Glaze thickens")
    assert "USDA" in r["answer_text"] and "165°F" in r["answer_text"]
    assert "I can't tell from a description or photo" in r["answer_text"]
    assert "safe to eat" not in r["answer_text"] and "Yes" not in r["answer_text"]
    assert r["uncertainty"] == "high" and r["proposed_action"] is None


async def test_proposal_arguments_come_from_the_query_not_the_model(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await active(client, alice, versions[GOCHU])

    async def wrong_args(req: CoachRequest) -> CoachResponse:
        if "timer" in req.query:
            act = ProposedAction(command="start_timer", timer_label="Evil", timer_seconds=86_000)
        else:
            act = ProposedAction(command="jump_to_step", step_index=1)
        return CoachResponse(
            answer_text="ok", grounded_session_revision=req.session_revision, proposed_action=act
        )

    use(client, Coach(wrong_args))
    url = f"/v1/sessions/{s['id']}/ask"
    r = ok(await client.post(url, json={"query": "take me to step 5"}, headers=alice))
    assert r["proposed_action"] == {"command": "jump_to_step", "step_index": 4, "timer": None}
    s = ok(await command(client, alice, s, "next"))  # step 2 has a 20-minute suggested timer
    r = ok(await client.post(url, json={"query": "start a timer"}, headers=alice))
    assert r["proposed_action"]["timer"] == {"label": "Rest", "duration_seconds": 1200}
    r = ok(await client.post(url, json={"query": "set a timer for 3 minutes"}, headers=alice))
    assert r["proposed_action"]["timer"]["duration_seconds"] == 180


async def test_session_deleted_during_the_coach_call_is_404(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await active(client, alice, versions[GOCHU])

    async def delete_meanwhile(req: CoachRequest) -> CoachResponse:
        await db_session.execute(text("delete from cooking_sessions where id = :i"), {"i": s["id"]})
        await db_session.commit()
        return CoachResponse(answer_text="ok", grounded_session_revision=req.session_revision)

    use(client, Coach(delete_meanwhile))
    r = await client.post(f"/v1/sessions/{s['id']}/ask", json={"query": "what now?"}, headers=alice)
    assert r.status_code == 404 and r.json()["error"]["code"] == "NOT_FOUND"


# ------------------------------------------------------------------ items 4, 12, 13, 17a


async def test_preferences_report_unrecognized(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    out = await set_prefs(
        client, alice, ["peanut and tree nut allergy", "dragon fruit"], ["lactose intolerant"]
    )
    assert out["allergies"] == ["peanut", "tree nuts", "dragon fruit"]
    assert out["avoid"] == ["milk"] and out["unrecognized"] == ["dragon fruit"]
    assert ok(await client.get("/v1/me/preferences", headers=alice))["unrecognized"] == [
        "dragon fruit"
    ]


async def test_free_form_source_is_ai_unless_vetted_and_warnings_persist(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    await set_prefs(client, alice, ["sesame"])
    offer = await suggest(client, alice, versions[GOCHU], "ing-4")  # honey
    maple = next(x for x in offer["suggestions"] if x["candidate"] == "maple syrup")
    s = await start_session(
        client,
        alice,
        versions[GOCHU],
        [
            {"ingredient_ref": "ing-4", "suggestion_id": maple["suggestion_id"]},
            {"ingredient_ref": "ing-9", "replacement": "made-up oil", "source": "rule"},
            {"ingredient_ref": "ing-7", "replacement": "ground ginger", "source": "rule"},
        ],
    )
    by_ref = {a["ingredient_ref"]: a for a in s["adaptations"]}
    assert (
        by_ref["ing-9"]["source"] == "ai" and by_ref["ing-9"]["label"] == "AI suggested adaptation"
    )
    assert by_ref["ing-7"]["source"] == "rule"
    assert by_ref["ing-4"]["allergy_warning"] == maple["allergy_warning"] is not None
    assert by_ref["ing-4"]["risks"] == maple["risks"]
    # Fix round 2 (item 4): free-form swaps get computed cautions (sesame allergy → label check).
    assert "Check every package label" in by_ref["ing-9"]["allergy_warning"]
    assert by_ref["ing-9"]["risks"] == []
    again = ok(await client.get(f"/v1/sessions/{s['id']}", headers=alice))  # relaunch
    assert {a["ingredient_ref"]: a for a in again["adaptations"]}["ing-4"]["risks"] == maple[
        "risks"
    ]


async def test_mid_session_allergy_flags_swaps_and_blocks_saving_them(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await active(
        client,
        alice,
        versions[GOCHU],
        adaptations=[{"ingredient_ref": "ing-9", "replacement": "peanut oil", "source": "rule"}],
    )
    assert s["adaptations"][0]["conflicts_with_allergies"] is False
    await set_prefs(client, alice, ["peanuts"])
    s = ok(await client.get(f"/v1/sessions/{s['id']}", headers=alice))
    assert s["adaptations"][0]["conflicts_with_allergies"] is True
    s = ok(
        await command(
            client, alice, s, "complete", outcome={"result": "cooked", "save_changes": True}
        )
    )
    assert s["outcome"]["saved_changes"] is False
    url = f"/v1/recipe-versions/{versions[GOCHU]}/my-variation"
    assert (await client.get(url, headers=alice)).status_code == 404


# ------------------------------------------------------------------ items 5, 16, 18d/e/f


async def test_one_policy_blocks_never_list_and_creator_notes(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    r = await client.post(
        "/v1/sessions",
        json={
            "recipe_version_id": versions[GOCHU],
            "adaptations": [
                {"ingredient_ref": "ing-2", "replacement": "gochugaru", "source": "ai"}
            ],
        },
        headers=alice,
    )
    assert r.status_code == 422 and "not a substitute" in r.json()["error"]["message"]
    r = await client.post(
        "/v1/sessions",
        json={
            "recipe_version_id": versions["egg-and-tomato-stir-fry"],
            "adaptations": [{"ingredient_ref": "ing-1", "replacement": "tofu", "source": "ai"}],
        },
        headers=alice,
    )
    assert r.status_code == 422  # explicit no-swap seed rule applies to free-form swaps too
    v = (
        await publish_new(
            client,
            alice,
            ingredients=[{"id": "ing-1", "name": "honey", "quantity": 1, "unit": "tbsp"}],
            steps=[
                {"id": "step-1", "instruction": "Warm the honey.", "ingredient_refs": ["ing-1"]}
            ],
            creator_notes=["Do not substitute the honey; nothing else sets the glaze."],
        )
    )["recipe_version_id"]
    res = await suggest(client, alice, v, "ing-1")
    assert res["cannot_substitute"] is True and "creator" in res["reason"].lower()
    s = await start_session(client, alice, v)
    r = await command(
        client,
        alice,
        s,
        "approve_adaptation",
        adaptation={"ingredient_ref": "ing-1", "replacement": "maple syrup", "source": "ai"},
    )
    assert r.status_code == 422


async def test_already_reverted_and_cancelled_409_carry_the_session(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await active(
        client,
        alice,
        versions[GOCHU],
        adaptations=[{"ingredient_ref": "ing-4", "replacement": "maple syrup", "source": "rule"}],
    )
    aid = s["adaptations"][0]["id"]
    s = ok(await command(client, alice, s, "revert_adaptation", adaptation_id=aid))
    s = ok(
        await command(client, alice, s, "start_timer", timer={"label": "x", "duration_seconds": 60})
    )
    tid = s["timers"][0]["id"]
    s = ok(await command(client, alice, s, "cancel_timer", timer_id=tid))
    for r in (
        await command(client, alice, s, "revert_adaptation", adaptation_id=aid),
        await command(client, alice, s, "cancel_timer", timer_id=tid),
    ):
        assert r.status_code == 409 and r.json()["error"]["code"] == "INVALID_TRANSITION"
        assert r.json()["error"]["details"]["session"]["revision"] == s["revision"]


def test_vetted_risk_strings_are_pinned() -> None:
    import json

    rules = {
        r["target"]: r
        for r in json.loads((FIXTURES_DIR / "substitution_rules.json").read_text())["rules"]
    }

    def risks(target: str, candidate: str) -> list[str]:
        return next(s["risks"] for s in rules[target]["suggestions"] if s["candidate"] == candidate)

    def conf(target: str, candidate: str) -> str:
        return next(
            s["confidence"] for s in rules[target]["suggestions"] if s["candidate"] == candidate
        )

    pinned = [
        (
            "neutral oil",
            "peanut oil",
            PEANUT_OIL,
        ),
        ("sugar", "honey", "Contains honey: not for babies under 1 year old."),
        ("sugar", "honey", "Honey is not vegan."),
        (
            "gochujang",
            "red miso + gochugaru + honey + water",
            "Contains honey: not for babies under 1 year old.",
        ),
        ("chicken thigh", "extra-firm tofu, pressed", "Contains soy."),
        ("spam", "smoked tofu, diced", "Contains soy."),
        ("bacon", "smoked tofu, diced", "Contains soy."),
        ("bacon", "smoked tofu, diced", "Fry in an extra 1 tsp oil."),
        ("olive oil", "butter + a splash of neutral oil", "Contains milk (butter)."),
        (
            "cooked rice",
            "freshly cooked rice, spread on a tray to cool for 15 minutes",
            RICE_HOLD,
        ),
        (
            "cooked rice",
            "cooked jasmine or long-grain rice",
            RICE_HOLD,
        ),
        (
            "chicken thigh",
            "chicken breast, cut the same size",
            BREAST,
        ),
        (
            "rice vinegar",
            "apple cider vinegar",
            NO_PRESERVE,
        ),
        (
            "rice vinegar",
            "lemon juice",
            NO_PRESERVE,
        ),
        ("mirin", "dry sherry + sugar", "Not cooking sherry (salted)."),
        ("mirin", "dry sherry + sugar", "Contains sulfites."),
        ("shaoxing wine", "dry sherry", "Use dry drinking sherry, not salted cooking sherry."),
        ("shaoxing wine", "dry white wine", "Contains sulfites."),
        ("soy sauce", "coconut aminos + a pinch of salt", "Labelled soy-free; check the label."),
        ("soy sauce", "coconut aminos + a pinch of salt", "Contains coconut."),
        (
            "sesame oil",
            "neutral oil + crushed toasted sesame seeds",
            "Contains sesame, same allergen as the original.",
        ),
        (
            "spaghetti",
            "gluten-free spaghetti",
            "Some gluten-free pasta contains corn, soy or egg; check the label.",
        ),
        ("honey", "brown sugar + a splash of water", "Burns faster in the pan."),
        (
            "tomato",
            "cherry tomatoes, halved",
            "Releases less juice; press or halve and add a splash of water.",
        ),
        ("lemon", "lime", "Zest only; for juice use 1:1 lime juice."),
        (
            "kimchi",
            "sauerkraut + gochugaru + garlic",
            "Drain it; sauerkraut is milder and saltier.",
        ),
    ]
    for target, candidate, risk in pinned:
        assert risk in risks(target, candidate), (target, candidate, risk)
    for target, candidate, level in [
        ("neutral oil", "peanut oil", "medium"),
        ("chicken thigh", "chicken breast, cut the same size", "medium"),
        ("rice vinegar", "lemon juice", "low"),
        ("salt", "fine sea salt or table salt", "medium"),
        ("ketchup", "tomato paste + sugar + water", "medium"),
        ("soy sauce", "tamari", "medium"),
        ("chili crisp", "red pepper flakes in a little neutral oil", "medium"),
        ("scallion", "chives", "medium"),
        ("honey", "maple syrup", "medium"),
        ("tomato", "cherry tomatoes, halved", "medium"),
    ]:
        assert conf(target, candidate) == level, (target, candidate)
    assert "sunflower or avocado oil" in [
        s["candidate"] for s in rules["neutral oil"]["suggestions"]
    ]
    assert all("rice vinegar" not in s["candidate"] for s in rules["lemon"]["suggestions"])
    assert {"sambal oelek", "doubanjiang", "gochugaru"} <= set(rules["gochujang"]["never"])
    no_safe = " ".join(json.dumps(r) for r in rules.values()).lower()
    assert "safe for you" not in no_safe and "vegetarian" not in no_safe and "certif" not in no_safe


async def test_never_list_is_exact_not_substring(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    res = await suggest(client, alice, versions[GOCHU], "ing-2")
    assert "red miso + gochugaru + honey + water" in {x["candidate"] for x in res["suggestions"]}


async def test_spam_or_bacon_resolves_to_both_rules(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    res = await suggest(client, alice, versions["kimchi-fried-rice"], "ing-11")
    cands = {x["candidate"] for x in res["suggestions"]}
    assert "ham, diced" in cands and "bacon" not in cands and "spam" not in cands


async def test_unknown_allergen_status_gets_a_specific_label_check(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    await set_prefs(client, alice, ["peanut"])
    res = await suggest(client, alice, versions["egg-and-tomato-stir-fry"], "ing-7")  # shaoxing
    sherry = next(x for x in res["suggestions"] if x["candidate"] == "dry sherry")
    assert "We don't know what dry sherry contains" in sherry["allergy_warning"]


# ------------------------------------------------------------------ item 16D (seed v2)


async def test_seed_publishes_fixture_changes_as_v2_and_v1_sessions_stay(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    from app.scripts.seed import load_fixtures, load_history

    v1_fixture = load_history(FIXTURES_DIR, GOCHU)[0]
    current = next(f for f in load_fixtures(FIXTURES_DIR) if f.slug == GOCHU)
    # An existing database that only ever saw v1 (before this fix round).
    await seed_fixtures(db_session, FIXTURES_DIR)  # dictionary, rules, everything
    await db_session.execute(text("SET LOCAL souslens.unlock_versions = 'on'"))
    await db_session.execute(
        text("update recipes set latest_version_id = null where slug = :s"), {"s": GOCHU}
    )
    await db_session.execute(
        text(
            "delete from recipe_versions v using recipes r where v.recipe_id = r.id and r.slug = :s"
        ),
        {"s": GOCHU},
    )
    await seed_recipe(db_session, v1_fixture)
    await db_session.commit()
    alice = await bearer(client, "alice@example.com")
    detail = ok(await client.get("/v1/recipes/a185d1a4-2726-57b9-9b17-069262cbf492", headers=alice))
    assert detail["version_number"] == 1
    s = await start_session(client, alice, detail["recipe_version_id"])

    first = await seed_recipe(db_session, current, [v1_fixture])
    await db_session.commit()
    assert first.created_version is True
    again = await seed_recipe(db_session, current, [v1_fixture])
    assert again.created_version is False and again.version_id == first.version_id
    count = await db_session.scalar(
        select(func.count())
        .select_from(RecipeVersion)
        .where(RecipeVersion.recipe_id == detail["recipe_id"])
    )
    assert count == 2
    latest = ok(await client.get(f"/v1/recipes/{detail['recipe_id']}", headers=alice))
    assert latest["version_number"] == 2 and "set it aside" in latest["steps"][0]["instruction"]
    still = ok(await client.get(f"/v1/sessions/{s['id']}", headers=alice))
    assert still["recipe"]["version_number"] == 1
    assert "set it aside" not in still["recipe"]["steps"][0]["instruction"]


# ------------------------------------------------------------------ items 7, 8, 9 (limits)


async def test_suggest_rate_limit_only_counts_advisor_calls(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    user = await _user(db_session, "alice@example.com")
    now = datetime.now(UTC)
    db_session.add_all(
        UsageEvent(user_id=user.id, kind="suggest", created_at=now) for _ in range(59)
    )
    db_session.add_all(  # older than twice the window: purged on the next reserve
        UsageEvent(user_id=user.id, kind="suggest", created_at=now - timedelta(hours=3))
        for _ in range(5)
    )
    await db_session.commit()
    res = await suggest(client, alice, versions[GOCHU], "ing-2")  # gochujang: exhaustive rule
    assert res["suggestions"]  # no advisor call, nothing counted
    await suggest(client, alice, versions[GOCHU], "ing-4")  # the 60th advisor call
    r = await client.post(
        "/v1/substitutions/suggest",
        json={"recipe_version_id": versions[GOCHU], "ingredient_ref": "ing-4"},
        headers=alice,
    )
    assert r.status_code == 429 and r.json()["error"]["code"] == "RATE_LIMITED"
    old = await db_session.scalar(
        select(func.count())
        .select_from(UsageEvent)
        .where(UsageEvent.created_at < now - timedelta(hours=2))
    )
    assert old == 0


async def test_live_suggestions_are_capped_per_user(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    user = await _user(db_session, "alice@example.com")
    old = datetime.now(UTC) - timedelta(hours=1)
    db_session.add_all(
        SubstitutionSuggestionRecord(
            owner_user_id=user.id,
            recipe_version_id=uuid.UUID(versions[GOCHU]),
            ingredient_ref="ing-4",
            payload_json={},
            created_at=old,
            expires_at=old + timedelta(hours=24),
        )
        for _ in range(250)
    )
    await db_session.commit()
    await suggest(client, alice, versions[GOCHU], "ing-2")
    n = await db_session.scalar(select(func.count()).select_from(SubstitutionSuggestionRecord))
    assert n == 200


async def test_command_cap_metadata_and_replay_window(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await active(client, alice, versions[GOCHU])
    r = await command(client, alice, s, "pause", metadata={"note": "x" * 201})
    assert r.status_code == 422
    # Replay window: the first key's response is dropped after 50 newer events.
    first_key = "first"
    s = ok(await command(client, alice, s, "pause", key=first_key))
    for _ in range(25):
        s = ok(await command(client, alice, s, "resume"))
        s = ok(await command(client, alice, s, "pause"))
    r = await command(client, alice, {**s, "revision": 1}, "pause", key=first_key)
    assert (
        r.status_code == 409
        and r.json()["error"]["details"]["session"]["revision"] == s["revision"]
    )
    # Per-session cap: 600 commands per hour.
    await db_session.execute(
        text(
            "insert into session_events (id, session_id, sequence, type, payload_json, created_at) "
            "select gen_random_uuid(), :s, 10000 + g, 'x', '{}'::jsonb, now() "
            "from generate_series(1, 600) g"
        ),
        {"s": s["id"]},
    )
    await db_session.commit()
    r = await command(client, alice, s, "resume")
    assert r.status_code == 429 and r.json()["error"]["code"] == "RATE_LIMITED"


# ------------------------------------------------------------------ item 17b (notes)


async def test_note_idempotency_key(client: AsyncClient, db_session: AsyncSession) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    s = await start_session(client, alice, versions[SALAD])
    url = f"/v1/sessions/{s['id']}/notes"
    h = {**alice, "Idempotency-Key": "note-1"}
    a = await client.post(url, json={"text": "less salt"}, headers=h)
    b = await client.post(url, json={"text": "less salt"}, headers=h)
    assert a.status_code == b.status_code == 201 and a.json() == b.json()
    c = await client.post(url, json={"text": "more salt"}, headers=h)
    assert c.status_code == 409 and c.json()["error"]["code"] == "STATE_CONFLICT"
    d = await client.post(url, json={"text": "less salt"}, headers=alice)  # no key: a new note
    assert d.status_code == 201 and d.json()["id"] != a.json()["id"]
    assert await db_session.scalar(select(func.count()).select_from(SessionNote)) == 2
