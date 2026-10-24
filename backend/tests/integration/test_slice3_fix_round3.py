"""Brief 005 fix round 3: allergy phrasings (C1), structural gaps (C2), adaptation rivals,
amounts and caution sentences (M1-M3), preference upsert and key cap (M4-M5)."""

from __future__ import annotations

import asyncio

import pytest
from httpx import AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import UserPreference
from app.domains.matching.dictionary import load_dictionary_file
from app.domains.recipes.schemas import IngredientOut, StepOut
from app.domains.safety.content import (
    StructuralContext,
    conflicts,
    normalize_preferences,
    sensitivities,
    structural_verdict,
)
from app.domains.substitutions.adapt import AdaptationSpec, adapt_step
from tests.conftest import FIXTURES_DIR, bearer
from tests.integration.slice3_helpers import seed, set_prefs, suggest
from tests.integration.test_publish import publish_new

D = load_dictionary_file(FIXTURES_DIR)


# ------------------------------------------------------------------ C1


@pytest.mark.parametrize(
    ("entry", "candidates"),
    [
        ("I'm allergic to peanuts", ["peanut butter", "peanut oil"]),
        ("severe peanut allergy", ["peanut butter", "peanut oil"]),
        ("anaphylactic to shellfish", ["shrimp", "crab"]),
        ("shellfish allergy (shrimp)", ["shrimp", "prawns"]),
        ("peanut or tree nut", ["cashews", "almond flour", "peanut oil"]),
        ("I am severely allergic to tree nuts", ["pistachios", "cashew"]),
        ("pea​nut", ["peanut oil"]),  # zero-width space
        ("sulphites", ["dry sherry", "sulfur dioxide"]),
        ("dragon fruit", ["dragon fruit salsa", "dried dragon"]),
    ],
)
def test_allergy_phrasings_block_conflicting_candidates(entry: str, candidates: list[str]) -> None:
    keys = normalize_preferences([entry], D)
    terms = sensitivities(keys, D)
    for candidate in candidates:
        assert conflicts(candidate, terms, D), (entry, keys, candidate)


def test_new_dictionary_entries() -> None:
    for name, flag in (
        ("cashew", "tree_nut"),
        ("pistachio", "tree_nut"),
        ("oats", "wheat"),
        ("sulfites", "sulfite"),
    ):
        entry = D.get(name)
        assert entry is not None and flag in entry.allergens, name
    assert D.get("coconut") is not None


async def test_allergy_phrasing_end_to_end(client: AsyncClient, db_session: AsyncSession) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    out = await set_prefs(client, alice, ["I'm allergic to peanuts"])
    assert out["allergies"] == ["peanut"]
    res = await suggest(client, alice, versions["gochujang-chicken-thighs"], "ing-9")
    assert "peanut oil" not in {s["candidate"] for s in res["suggestions"]}


# ------------------------------------------------------------------ C2


def _ctx(
    names: set[str], steps: tuple[str, ...], recipe: tuple[str, ...] = ()
) -> StructuralContext:
    return StructuralContext(frozenset(names), steps, recipe)


def test_structural_gaps() -> None:
    # Pickling recipe identified by its title only.
    assert (
        structural_verdict(
            _ctx({"rice vinegar"}, ("Pour over the onions.",), ("Quick Pickled Onions",))
        )
        is not None
    )
    assert (
        structural_verdict(
            _ctx({"egg yolk"}, ("Whisk the yolk with anchovy and oil.",), ("Caesar dressing",))
        )
        is not None
    )
    assert (
        structural_verdict(_ctx({"gelatin"}, ("Bloom and stir into the cream.",), ("Panna cotta",)))
        is not None
    )
    assert structural_verdict(_ctx({"cornstarch"}, ("Whisk until thick and set.",))) is not None
    assert (
        structural_verdict(_ctx({"egg"}, ("Whisk everything together.",), ("Classic Tiramisu",)))
        is not None
    )  # title-only raw egg
    assert structural_verdict(_ctx({"egg white"}, ("Whip to stiff peaks.",))) is not None
    assert structural_verdict(_ctx({"fish sauce"}, ("Mix.",), ("Homemade Kimchi",))) is not None
    assert structural_verdict(_ctx({"salt"}, ("Toss and drain.",), ("Cucumber Salad",))) is None
    assert structural_verdict(_ctx({"cornstarch"}, ("Toss the chicken in it.",))) is None


async def test_quick_pickled_onions_lemon_swap_blocked(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    v = (
        await publish_new(
            client,
            alice,
            title="Quick Pickled Onions",
            ingredients=[
                {"id": "ing-1", "name": "rice vinegar", "quantity": 1, "unit": "cup"},
                {"id": "ing-2", "name": "red onion", "quantity": 1},
            ],
            steps=[
                {
                    "id": "step-1",
                    "instruction": "Pour the vinegar over the sliced onion.",
                    "ingredient_refs": ["ing-1", "ing-2"],
                }
            ],
        )
    )["recipe_version_id"]
    res = await suggest(client, alice, v, "ing-1")
    assert res["cannot_substitute"] is True and res["suggestions"] == []
    r = await client.post(
        "/v1/sessions",
        json={
            "recipe_version_id": v,
            "adaptations": [
                {"ingredient_ref": "ing-1", "replacement": "lemon juice", "source": "rule"}
            ],
        },
        headers=alice,
    )
    assert r.status_code == 422


# ------------------------------------------------------------------ M1-M3


INGS = {
    i.id: i
    for i in (
        IngredientOut(id="i1", name="chicken thigh"),
        IngredientOut(id="i2", name="chicken stock"),
        IngredientOut(id="i3", name="egg"),
        IngredientOut(id="i4", name="garlic"),
        IngredientOut(id="i5", name="mirin"),
        IngredientOut(id="i6", name="parmesan"),
    )
}


def _adapt(text: str, refs: list[str], spec: AdaptationSpec) -> str:
    return adapt_step(
        StepOut(id="s", order=0, instruction=text, ingredient_refs=refs), [spec], INGS, D
    )[0]


def test_longer_foods_stay_untouched() -> None:
    assert _adapt(
        "Add the chicken and the chicken stock.",
        ["i1", "i2"],
        AdaptationSpec("a", "i1", "chicken thigh", "tofu"),
    ) == ("Add the tofu and the chicken stock.")
    assert _adapt(
        "Beat the egg, then boil the egg noodles.",
        ["i3"],
        AdaptationSpec("a", "i3", "egg", "silken tofu"),
    ) == ("Beat the silken tofu, then boil the egg noodles.")
    assert _adapt(
        "Rub with garlic and garlic powder.", ["i4"], AdaptationSpec("a", "i4", "garlic", "shallot")
    ) == ("Rub with shallot and garlic powder.")


def test_amount_span_is_replaced_once_or_annotated() -> None:
    assert _adapt(
        "Grate 1/4 cup parmesan over it.",
        ["i6"],
        AdaptationSpec("a", "i6", "parmesan", "butter", "1 tbsp butter"),
    ) == ("Grate 1 tbsp butter over it.")
    got = _adapt(
        "Add 2 tbsp of the mirin, then more mirin.",
        ["i5"],
        AdaptationSpec(
            "a",
            "i5",
            "mirin",
            "dry sherry + sugar",
            "1 tbsp dry sherry + 1 tsp sugar per 1 tbsp mirin",
        ),
    )
    assert got.count("per 1 tbsp mirin") == 1 and "(1 tbsp" not in got
    assert got.startswith("Add 2 tbsp of the dry sherry + sugar, then more dry sherry + sugar.")


def test_caution_sentences_are_annotated_not_rewritten() -> None:
    got = _adapt(
        "Toss in the garlic. Do not let the garlic burn.",
        ["i4"],
        AdaptationSpec("a", "i4", "garlic", "shallot"),
    )
    assert got == (
        "Toss in the shallot. Do not let the garlic burn. "
        "(Swap: use shallot instead of the garlic.)"
    )
    got = _adapt(
        "Warning: the garlic burns fast.", ["i4"], AdaptationSpec("a", "i4", "garlic", "shallot")
    )
    assert got == "Warning: the garlic burns fast. (Swap: use shallot instead of the garlic.)"


# ------------------------------------------------------------------ M4-M5


async def test_concurrent_first_preferences_put(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    bodies = [{"allergies": ["peanut"], "avoid": []}, {"allergies": ["sesame"], "avoid": []}]
    responses = await asyncio.gather(
        *(client.put("/v1/me/preferences", json=b, headers=alice) for b in bodies * 3)
    )
    assert [r.status_code for r in responses] == [200] * 6
    assert await db_session.scalar(select(func.count()).select_from(UserPreference)) == 1
    final = (await client.get("/v1/me/preferences", headers=alice)).json()
    assert final["allergies"] in (["peanut"], ["sesame"])


async def test_split_keys_are_capped(client: AsyncClient, db_session: AsyncSession) -> None:
    await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    entries = [", ".join(f"food{i}x{j}" for j in range(3)) for i in range(21)]  # 63 keys
    r = await client.put(
        "/v1/me/preferences", json={"allergies": entries, "avoid": []}, headers=alice
    )
    assert r.status_code == 422 and "at most 60" in r.json()["error"]["message"]
