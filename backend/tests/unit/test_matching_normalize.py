"""Ingredient dictionary integrity and name normalisation (PRD §12.1, §17.1, brief 004)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.domains.matching.dictionary import (
    DictEntry,
    DictionaryConflict,
    IngredientDictionary,
    clean,
    load_dictionary_file,
    read_dictionary_file,
    singularize_word,
)
from app.domains.matching.normalize import alternatives, normalize

FIXTURES_DIR = Path(__file__).resolve().parents[2].parent / "fixtures"


@pytest.fixture(scope="module")
def d() -> IngredientDictionary:
    return load_dictionary_file(FIXTURES_DIR)


def key(text: str, d: IngredientDictionary) -> str:
    return normalize(text, d).key


# --- dictionary file ----------------------------------------------------------------------


def test_dictionary_has_at_least_80_entries_and_no_alias_collisions(
    d: IngredientDictionary,
) -> None:
    # load_dictionary_file builds strictly: a duplicate canonical or alias would have raised.
    assert len(d) >= 80


def test_dictionary_covers_every_seeded_recipe_ingredient(d: IngredientDictionary) -> None:
    unresolved = []
    for path in sorted((FIXTURES_DIR / "seeded_recipes").glob("*.json")):
        for ing in json.loads(path.read_text())["ingredients"]:
            for alt in alternatives(ing["name"]):
                if normalize(alt, d).entry is None:
                    unresolved.append(f"{path.stem}: {alt}")
    assert unresolved == []


def test_ambiguity_links_point_at_real_entries() -> None:
    data = read_dictionary_file(FIXTURES_DIR)
    names = {clean(e.canonical_name) for e in data.ingredients}
    for entry in data.ingredients:
        assert set(entry.ambiguous_with) <= names, entry.canonical_name


def test_allergen_flags_use_a_closed_vocabulary() -> None:
    allowed = {"egg", "milk", "wheat", "soy", "peanut", "tree_nut", "sesame", "fish", "shellfish"}
    allowed.add("mustard")
    allowed.add("sulfite")  # brief 005 fix round 3: sulfites entry
    for entry in read_dictionary_file(FIXTURES_DIR).ingredients:
        assert set(entry.allergens) <= allowed, entry.canonical_name


def test_build_refuses_an_alias_claimed_by_two_entries() -> None:
    with pytest.raises(DictionaryConflict):
        IngredientDictionary.build(
            [
                DictEntry(canonical_name="gochujang", aliases=("korean chili",)),
                DictEntry(canonical_name="gochugaru", aliases=("korean chili",)),
            ]
        )


def test_lenient_build_keeps_the_first_claimant() -> None:
    d = IngredientDictionary.build(
        [
            DictEntry(canonical_name="gochujang", aliases=("korean chili",)),
            DictEntry(canonical_name="gochugaru", aliases=("korean chili",)),
        ],
        strict=False,
    )
    assert normalize("korean chili", d).key == "gochujang"


# --- PRD §17.1 ----------------------------------------------------------------------------


@pytest.mark.parametrize("name", ["scallion", "green onion", "Spring Onions", "  scallions  "])
def test_scallion_equals_green_onion_equals_spring_onion(
    name: str, d: IngredientDictionary
) -> None:
    assert key(name, d) == "scallion"


def test_gochujang_is_not_gochugaru(d: IngredientDictionary) -> None:
    assert key("gochujang", d) == "gochujang"
    assert key("gochugaru", d) == "gochugaru"
    assert key("Korean chili paste", d) == "gochujang"
    assert key("korean red pepper flakes", d) == "gochugaru"


# --- normalisation steps ------------------------------------------------------------------


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("  Green   ONIONS ", "scallion"),
        ("tomatoes", "tomato"),
        ("Eggs", "egg"),
        ("potatoes", "potato"),
        ("cherries", "cherry"),  # not an entry: conservative fallback singular
        ("apples", "apple"),
        ("molasses", "molasses"),  # an entry itself: never singularised to "molasse"
        ("prawns", "shrimp"),
        ("ripe tomato", "tomato"),
        ("large eggs", "egg"),
        ("boneless skinless chicken thighs", "chicken thigh"),
        ("roasted seaweed (gim)", "roasted seaweed"),
        ("extra-virgin olive oil", "olive oil"),
        ("kosher salt", "salt"),
        ("napa cabbage kimchi", "kimchi"),
        ("flat-leaf parsley", "parsley"),
        ("Jalapeño", "jalapeño"),
        ("jalapeno peppers", "jalapeño"),
    ],
)
def test_normalisation_examples(text: str, expected: str, d: IngredientDictionary) -> None:
    assert key(text, d) == expected


def test_unknown_names_keep_a_stable_key_and_no_entry(d: IngredientDictionary) -> None:
    n = normalize("Dragon fruits", d)
    assert n.key == "dragon fruit"
    assert n.entry is None and n.ingredient_id is None


def test_empty_or_punctuation_only_is_empty_key(d: IngredientDictionary) -> None:
    assert key("   ", d) == ""
    assert key("!!!", d) == ""


@pytest.mark.parametrize(
    ("a", "b"),
    [
        ("cooked rice", "rice"),
        ("cooked short-grain rice", "short-grain rice"),
        ("dried basil", "fresh basil"),
        ("dried cilantro", "cilantro"),
        ("ground ginger", "fresh ginger"),
        ("ground cinnamon", "cinnamon stick"),
        ("ground cumin", "cumin seed"),
        ("black pepper", "black peppercorn"),
    ],
)
def test_identity_qualifiers_are_preserved(a: str, b: str, d: IngredientDictionary) -> None:
    assert key(a, d) != key(b, d)


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("fresh basil", "basil"),
        ("fresh garlic", "garlic"),
        ("raw chicken thighs", "chicken thigh"),
        ("cooked jasmine rice", "cooked rice"),
        ("uncooked rice", "rice"),
        ("dried basil leaves", "dried basil"),
        ("dried oregano", "dried oregano"),
    ],
)
def test_implied_qualifiers_resolve_to_the_entry(
    text: str, expected: str, d: IngredientDictionary
) -> None:
    assert key(text, d) == expected


def test_unlisted_qualified_variant_keeps_its_qualifier(d: IngredientDictionary) -> None:
    n = normalize("dried tomatoes", d)
    assert n.key == "dried tomato"
    assert n.entry is None
    assert n.qualifiers == frozenset({"dried"})
    assert key("cooked chicken", d) == "cooked chicken"
    assert key("sweetened yogurt", d) == "sweetened plain yogurt"


@pytest.mark.parametrize(
    ("a", "b"),
    [
        ("peanut oil", "vegetable oil"),
        ("almond milk", "milk"),
        ("oat milk", "milk"),
        ("tamari", "soy sauce"),
        ("peanut butter", "butter"),
        ("almond butter", "butter"),
        ("fish sauce", "soy sauce"),
    ],
)
def test_distinct_allergen_identities_never_normalise_together(
    a: str, b: str, d: IngredientDictionary
) -> None:
    assert key(a, d) != key(b, d)


def test_allergen_flags_travel_with_the_entry(d: IngredientDictionary) -> None:
    peanut = normalize("groundnut oil", d).entry
    neutral = normalize("canola oil", d).entry
    assert peanut is not None and "peanut" in peanut.allergens
    assert neutral is not None and neutral.allergens == ()


def test_generic_names_expose_ambiguity(d: IngredientDictionary) -> None:
    assert "chicken thigh" in normalize("chicken", d).ambiguous_with
    assert "gochujang" in normalize("chili paste", d).ambiguous_with
    assert normalize("chicken thighs", d).ambiguous_with == ()


def test_alternatives_split_on_or() -> None:
    assert alternatives("spam or bacon") == ["spam", "bacon"]
    assert alternatives("Garlic") == ["garlic"]


@pytest.mark.parametrize(
    ("word", "singular"),
    [
        ("berries", "berry"),
        ("tomatoes", "tomato"),
        ("peaches", "peach"),
        ("hummus", "hummus"),
        ("asparagus", "asparagus"),
        ("couscous", "couscous"),
        ("glass", "glass"),
        ("peas", "peas"),
    ],
)
def test_fallback_singularisation_is_conservative(word: str, singular: str) -> None:
    assert singularize_word(word) == singular
