"""Brief 005: vetted rule fixture, deterministic step adaptation, timer suggestions, intents."""

from __future__ import annotations

import json

import pytest

from app.domains.matching.dictionary import IngredientDictionary, load_dictionary_file
from app.domains.recipes.schemas import IngredientOut, StepOut
from app.domains.sessions import intent
from app.domains.substitutions.adapt import AdaptationSpec, compose_overlay, suggested_timer
from app.domains.substitutions.rules import read_rules_file
from app.domains.substitutions.service import target_names
from tests.conftest import FIXTURES_DIR


@pytest.fixture(scope="module")
def d() -> IngredientDictionary:
    return load_dictionary_file(FIXTURES_DIR)


def test_rules_cover_every_seeded_ingredient(d: IngredientDictionary) -> None:
    rules = {r.target: r for r in read_rules_file(FIXTURES_DIR).rules}
    assert all(d.get(t) is not None for t in rules), "every target is a dictionary entry"
    missing = []
    for path in sorted((FIXTURES_DIR / "seeded_recipes").glob("*.json")):
        for ing in json.loads(path.read_text())["ingredients"]:
            names = target_names(ing["name"], d)
            if not any(n in rules for n in names):
                missing.append((path.stem, ing["name"]))
    assert missing == []


def test_gochujang_rule_is_honest(d: IngredientDictionary) -> None:
    rule = next(r for r in read_rules_file(FIXTURES_DIR).rules if r.target == "gochujang")
    assert rule.exhaustive and "gochugaru" in rule.never
    assert all(s.confidence == "low" for s in rule.suggestions)
    assert all(s.candidate.strip() != "gochugaru" for s in rule.suggestions)
    no_swaps = [r.target for r in read_rules_file(FIXTURES_DIR).rules if r.no_swap_reason]
    assert {"egg", "cucumber"} <= set(no_swaps)


def _step(sid: str, text: str, refs: list[str], order: int = 0) -> StepOut:
    return StepOut(id=sid, order=order, instruction=text, ingredient_refs=refs)


def test_mention_replace_plural_case_and_annotation(d: IngredientDictionary) -> None:
    ings = [IngredientOut(id="ing-1", name="ripe tomato"), IngredientOut(id="ing-2", name="egg")]
    steps = [
        _step("s1", "Tomatoes go in first. Add the tomato wedges.", ["ing-1"]),
        _step("s2", "Stir everything.", ["ing-1"]),
        _step("s3", "Tomatoes are mentioned but not referenced.", []),
    ]
    spec = AdaptationSpec("a1", "ing-1", "ripe tomato", "cherry tomatoes")
    overlay = compose_overlay(steps, ings, [spec], d)
    assert (
        overlay["s1"]["instruction"]
        == "Cherry tomatoes go in first. Add the cherry tomatoes wedges."
    )
    assert overlay["s2"]["instruction"] == (
        "Stir everything. (Swap: use cherry tomatoes instead of the ripe tomato.)"
    )
    # An untagged step that names the ingredient is annotated, never rewritten.
    assert overlay["s3"]["instruction"] == (
        "Tomatoes are mentioned but not referenced. "
        "(Swap: use cherry tomatoes instead of the ripe tomato.)"
    )
    assert steps[0].instruction.startswith("Tomatoes")  # the original is untouched


def test_longer_mention_of_another_ingredient_is_protected(d: IngredientDictionary) -> None:
    ings = [
        IngredientOut(id="ing-1", name="napa cabbage kimchi"),
        IngredientOut(id="ing-2", name="kimchi juice"),
    ]
    step = _step("s1", "Chop the kimchi; add the kimchi juice.", ["ing-1", "ing-2"])
    overlay = compose_overlay([step], ings, [AdaptationSpec("a", "ing-1", "kimchi", "XX")], d)
    assert overlay["s1"]["instruction"] == "Chop the XX; add the kimchi juice."


def test_two_swaps_in_one_step_never_rewrite_each_other(d: IngredientDictionary) -> None:
    ings = [IngredientOut(id="ing-1", name="mirin"), IngredientOut(id="ing-2", name="sugar")]
    step = _step("s1", "Stir the mirin and sugar.", ["ing-1", "ing-2"])
    specs = [
        AdaptationSpec("a", "ing-1", "mirin", "rice vinegar + a pinch of sugar"),
        AdaptationSpec("b", "ing-2", "sugar", "honey"),
    ]
    overlay = compose_overlay([step], ings, specs, d)
    assert overlay["s1"] == {
        "instruction": "Stir the rice vinegar + a pinch of sugar and honey.",
        "adaptation_ids": ["a", "b"],
    }


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("toss with the salt and leave them to drain for 10 minutes.", ("Drain", 600)),
        ("Let it simmer for 4 to 6 minutes.", ("Simmer", 240)),
        ("Serve within 30 minutes while it is still crunchy.", None),
        ("Set a timer for 2 minutes less than the package time.", None),
        ("Stir for the first 30 seconds.", None),
        ("Bake for 1 hour.", ("Bake", 3600)),
    ],
)
def test_suggested_timer(text: str, expected: tuple[str, int] | None) -> None:
    got = suggested_timer(text, 0)
    assert (got and (got["label"], got["duration_seconds"])) == (expected or None)


def test_intents_come_from_the_query_only() -> None:
    assert intent.intents("ok next step") == {"next"}
    assert intent.intents("next") == {"next"}
    assert intent.intents("go back") == {"back"}
    assert intent.jump_target("take me to step 5") == 4
    assert intent.intents("set a timer for 10 min") == {"start_timer"}
    assert intent.duration_seconds("set a timer for 10 min") == 600
    assert intent.intents("what does finely minced mean?") == set()


def test_generic_suffix_is_not_rewritten_and_amounts_carry_the_ratio(
    d: IngredientDictionary,
) -> None:
    ings = [IngredientOut(id="ing-1", name="neutral oil"), IngredientOut(id="ing-2", name="mirin")]
    steps = [
        _step("s1", "Heat the oil until it shimmers.", ["ing-1"]),
        _step("s2", "Add 2 tbsp of the mirin and stir.", ["ing-2"]),
    ]
    specs = [
        AdaptationSpec("a", "ing-1", "neutral oil", "light olive oil"),
        AdaptationSpec("b", "ing-2", "mirin", "dry sherry + sugar", "1 tbsp sherry + 1 tsp sugar"),
    ]
    overlay = compose_overlay(steps, ings, specs, d)
    assert overlay["s1"]["instruction"] == (
        "Heat the oil until it shimmers. (Swap: use light olive oil instead of the neutral oil.)"
    )
    # Fix round 3 (M2): the ratio does not read as a plain amount of the replacement, so the
    # name is replaced and ONE annotation carries the ratio (no second amount in the text).
    assert overlay["s2"]["instruction"] == (
        "Add 2 tbsp of the dry sherry + sugar and stir. (Swap: use dry sherry + sugar instead of "
        "the mirin: 1 tbsp sherry + 1 tsp sugar.)"
    )


@pytest.mark.parametrize(
    "query",
    [
        "what's the last step",
        "should I continue stirring",
        "next time I'll add more salt",
        "what's next in the sauce",
    ],
)
def test_non_navigation_phrases(query: str) -> None:
    assert intent.intents(query) == set()
