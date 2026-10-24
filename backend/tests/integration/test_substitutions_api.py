"""Brief 005: preferences and ``POST /substitutions/suggest`` (SUB-01/02/05, PRD §8.4)."""

from __future__ import annotations

import uuid

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from tests.conftest import bearer
from tests.integration.slice3_helpers import seed, set_prefs, suggest
from tests.integration.test_publish import publish_new

GOCHU = "gochujang-chicken-thighs"
SALAD = "cucumber-salad"
PASTA = "garlic-pasta"
EGGS = "egg-and-tomato-stir-fry"


def recipe(ingredients: list[dict], steps: list[dict], **extra: object) -> dict[str, object]:
    return {"ingredients": ingredients, "steps": steps, **extra}


MIRIN_RECIPE = recipe(
    [
        {"id": "ing-1", "name": "mirin", "quantity": 2, "unit": "tbsp"},
        {"id": "ing-2", "name": "soy sauce", "quantity": 2, "unit": "tbsp"},
        {"id": "ing-3", "name": "salmon fillet", "quantity": 2},
    ],
    [
        {
            "id": "step-1",
            "instruction": "Stir the mirin and soy sauce together.",
            "ingredient_refs": ["ing-1", "ing-2"],
        },
        {
            "id": "step-2",
            "instruction": "Brush the salmon with the glaze and broil for 6 minutes.",
            "ingredient_refs": ["ing-3", "ing-1"],
        },
    ],
    title="Mirin Glazed Salmon",
)


async def test_preferences_normalised_and_bounded(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    r = await client.get("/v1/me/preferences", headers=alice)
    assert r.json() == {"allergies": [], "avoid": [], "updated_at": None, "unrecognized": []}
    out = await set_prefs(
        client,
        alice,
        ["Peanuts", "tree nuts", "Shellfish", "gluten", "dairy", "peanut"],
        ["cilantro", "Peanuts", "spring onions"],
    )
    assert out["allergies"] == ["peanut", "tree nuts", "shellfish", "gluten", "milk"]
    assert out["avoid"] == ["cilantro", "scallion"]  # peanut already a hard block
    assert out["updated_at"]
    assert (await client.get("/v1/me/preferences", headers=alice)).json() == out
    for bad in (
        {"allergies": ["x" * 61]},
        {"avoid": ["a"] * 31},
        {"allergies": [""]},
        {"allergies": ["ok"], "extra": 1},
    ):
        assert (await client.put("/v1/me/preferences", json=bad, headers=alice)).status_code == 422
    bob = await bearer(client, "bob@example.com")
    assert (await client.get("/v1/me/preferences", headers=bob)).json()["allergies"] == []


async def test_mirin_rule_suggestion_with_adjusted_steps(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    v = (await publish_new(client, alice, **MIRIN_RECIPE))["recipe_version_id"]
    res = await suggest(client, alice, v, "ing-1")
    assert res["target_ingredient"] == "mirin" and res["cannot_substitute"] is False
    first = res["suggestions"][0]
    assert first["source"] == "rule"
    # Content-vetted (fix round 1): mirin is sweet, not acidic, so water + sugar, not a pinch.
    assert first["candidate"] == "rice vinegar + water + sugar"
    assert first["ratio_or_amount"] and first["impact_flavor"] and first["impact_texture"]
    assert first["confidence"] in {"high", "medium", "low"}
    assert first["risks"] and first["requires_user_confirmation"] is True
    assert first["kind"] in {"close_equivalent", "flavor_adaptation", "structural_substitution"}
    adjusted = {a["step_id"]: a["instruction"] for a in first["adjusted_steps"]}
    assert adjusted == {
        "step-1": "Stir the rice vinegar + water + sugar and soy sauce together.",
        "step-2": "Brush the salmon with the glaze and broil for 6 minutes. "
        "(Swap: use rice vinegar + water + sugar instead of the mirin.)",
    }
    assert len(res["suggestions"]) <= 3
    assert len({s["suggestion_id"] for s in res["suggestions"]}) == len(res["suggestions"])


async def test_gochujang_is_honest_low_confidence_never_gochugaru(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    res = await suggest(client, alice, versions[GOCHU], "ing-2")
    assert res["suggestions"], res
    for s in res["suggestions"]:
        assert s["confidence"] == "low" and s["kind"] == "flavor_adaptation"
        assert s["candidate"].strip().lower() != "gochugaru"
        assert any("not a true equivalent" in r.lower() for r in s["risks"])
    assert any(
        "gochugaru alone is not a swap" in r.lower() for s in res["suggestions"] for r in s["risks"]
    )


async def test_allergy_drops_and_target_allergen_notice(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    # neutral oil → light olive oil, peanut oil; a peanut allergy drops peanut oil.
    plain = await suggest(client, alice, versions[GOCHU], "ing-9")
    assert "peanut oil" in {s["candidate"] for s in plain["suggestions"]}
    await set_prefs(client, alice, ["peanuts"])
    res = await suggest(client, alice, versions[GOCHU], "ing-9")
    assert "peanut oil" not in {s["candidate"] for s in res["suggestions"]}
    assert res["suggestions"] and res["reason"]  # says something was left out
    for s in res["suggestions"]:
        assert s["allergy_warning"] and "label" in s["allergy_warning"].lower()
        assert "safe for you" not in (s["allergy_warning"] + " ".join(s["risks"])).lower()
    # soy sauce for a soy-allergic cook: notice about the recipe, tamari dropped, aminos kept.
    await set_prefs(client, alice, ["soy"])
    res = await suggest(client, alice, versions[SALAD], "ing-5")
    assert res["safety_notice"] and "soy sauce" in res["safety_notice"]
    cands = {s["candidate"] for s in res["suggestions"]}
    assert "tamari" not in cands and "coconut aminos + a pinch of salt" in cands


async def test_everything_blocked_is_cannot_substitute(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    await set_prefs(client, alice, ["milk"])
    # parmesan: pecorino and butter carry milk; nutritional yeast survives.
    res = await suggest(client, alice, versions[PASTA], "ing-7")
    assert [s["candidate"] for s in res["suggestions"]] == ["nutritional yeast"]
    await set_prefs(client, alice, ["milk", "nutritional yeast"])
    res = await suggest(client, alice, versions[PASTA], "ing-7")
    assert res["cannot_substitute"] is True and res["suggestions"] == []
    assert "allergy" in res["reason"].lower()
    await set_prefs(client, alice, [], ["pecorino romano", "butter", "nutritional yeast"])
    res = await suggest(client, alice, versions[PASTA], "ing-7")
    assert res["cannot_substitute"] is True and "preference" in res["reason"].lower()


async def test_explicit_no_swap_and_unknown_ingredient(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    res = await suggest(client, alice, versions[EGGS], "ing-1")  # egg: explicit no-swap rule
    assert res["cannot_substitute"] is True and res["suggestions"] == [] and res["reason"]
    v = (
        await publish_new(
            client,
            alice,
            **recipe(
                [{"id": "ing-1", "name": "saffron", "quantity": 1, "unit": "pinch"}],
                [
                    {
                        "id": "step-1",
                        "instruction": "Bloom the saffron.",
                        "ingredient_refs": ["ing-1"],
                    }
                ],
            ),
        )
    )["recipe_version_id"]
    res = await suggest(client, alice, v, "ing-1")  # no rule, mock advisor has nothing
    assert res["cannot_substitute"] is True and res["suggestions"] == []
    assert "no suitable substitute" in res["reason"].lower()


async def test_scenario4_safety_critical_ingredients_get_no_suggestion(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """PRD §17.2 scenario 4: a safety-critical ingredient → no confident suggestion."""
    await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    cases = [
        recipe(
            [
                {"id": "ing-1", "name": "baking soda", "quantity": 1, "unit": "tsp"},
                {"id": "ing-2", "name": "flour", "quantity": 2, "unit": "cup"},
            ],
            [
                {
                    "id": "step-1",
                    "instruction": "Whisk the baking soda into the flour.",
                    "ingredient_refs": ["ing-1", "ing-2"],
                }
            ],
            title="Soda Bread",
        ),
        recipe(
            [
                {"id": "ing-1", "name": "white vinegar", "quantity": 2, "unit": "cup"},
                {"id": "ing-2", "name": "cucumber", "quantity": 4},
            ],
            [
                {
                    "id": "step-1",
                    "instruction": "Pour the hot vinegar brine over the cucumbers and process "
                    "the jars in a water bath canner for 10 minutes.",
                    "ingredient_refs": ["ing-1", "ing-2"],
                }
            ],
            title="Canned Dill Pickles",
        ),
        recipe(
            [
                {"id": "ing-1", "name": "egg yolk", "quantity": 1},
                {"id": "ing-2", "name": "neutral oil", "quantity": 1, "unit": "cup"},
            ],
            [
                {
                    "id": "step-1",
                    "instruction": "Whisk the egg yolk and drizzle in the oil to make mayonnaise.",
                    "ingredient_refs": ["ing-1", "ing-2"],
                }
            ],
            title="Homemade Mayo",
        ),
    ]
    for body in cases:
        v = (await publish_new(client, alice, **body))["recipe_version_id"]
        res = await suggest(client, alice, v, "ing-1")
        assert res["cannot_substitute"] is True, body["title"]
        assert res["suggestions"] == [] and "not recommended" in res["reason"].lower()


async def test_creator_warning_forbidding_swaps_wins(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    v = (
        await publish_new(
            client,
            alice,
            **recipe(
                [{"id": "ing-1", "name": "honey", "quantity": 1, "unit": "tbsp"}],
                [
                    {
                        "id": "step-1",
                        "instruction": "Warm the honey.",
                        "ingredient_refs": ["ing-1"],
                        "warnings": ["Do not substitute the honey; the glaze will not set."],
                    }
                ],
            ),
        )
    )["recipe_version_id"]
    res = await suggest(client, alice, v, "ing-1")
    assert res["cannot_substitute"] is True and "creator" in res["reason"].lower()


async def test_validation_and_access(client: AsyncClient, db_session: AsyncSession) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    bob = await bearer(client, "bob@example.com")
    r = await client.post(
        "/v1/substitutions/suggest",
        json={"recipe_version_id": versions[GOCHU], "ingredient_ref": "ing-99"},
        headers=alice,
    )
    assert r.status_code == 422
    r = await client.post(
        "/v1/substitutions/suggest",
        json={"recipe_version_id": str(uuid.uuid4()), "ingredient_ref": "ing-1"},
        headers=alice,
    )
    assert r.status_code == 404
    private = await publish_new(client, alice, **MIRIN_RECIPE)
    await client.post(f"/v1/recipes/{private['recipe_id']}/unpublish", json={}, headers=alice)
    r = await client.post(
        "/v1/substitutions/suggest",
        json={"recipe_version_id": private["recipe_version_id"], "ingredient_ref": "ing-1"},
        headers=bob,
    )
    assert r.status_code == 404
    assert (await client.post("/v1/substitutions/suggest", json={})).status_code == 401
