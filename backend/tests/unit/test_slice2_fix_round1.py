"""Brief 004 fix round 1: sums, photo estimates, normalisation wins (items 1, 2, 9)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from app.domains.matching.dictionary import IngredientDictionary, load_dictionary_file
from app.domains.matching.fit import PantryEntry, RecipeIngredient, fit
from app.domains.matching.normalize import alternatives, conjuncts, normalize

FIXTURES_DIR = Path(__file__).resolve().parents[2].parent / "fixtures"
NOW = datetime(2026, 10, 23, 12, 0, tzinfo=UTC)


@pytest.fixture(scope="module")
def d() -> IngredientDictionary:
    return load_dictionary_file(FIXTURES_DIR)


def have(
    d: IngredientDictionary,
    label: str,
    quantity: float | None = None,
    unit: str | None = None,
    *,
    estimate: bool = False,
) -> PantryEntry:
    return PantryEntry(
        id=uuid.uuid4(),
        raw_label=label,
        normalized_name=normalize(label, d).key,
        quantity=quantity,
        unit=unit,
        last_confirmed_at=NOW - timedelta(hours=1),
        quantity_is_estimate=estimate,
    )


def line(d: IngredientDictionary, name: str, quantity=None, unit=None, *pantry: PantryEntry):  # type: ignore[no-untyped-def]
    ing = RecipeIngredient(id="ing-1", name=name, quantity=quantity, unit=unit)
    return fit(uuid.uuid4(), [ing], list(pantry), d, NOW).items[0]


# --- 1. never sum across alternatives -----------------------------------------------------


def test_alternatives_are_never_summed_together(d: IngredientDictionary) -> None:
    got = line(
        d,
        "milk or heavy cream",
        1,
        "cup",
        have(d, "milk", 0.5, "cup"),
        have(d, "heavy cream", 0.5, "cup"),
    )
    assert got.status == "uncertain"


def test_one_alternative_alone_is_enough(d: IngredientDictionary) -> None:
    got = line(d, "milk or heavy cream", 1, "cup", have(d, "milk", 1, "cup"))
    assert got.status == "available"


def test_entries_of_one_alternative_still_add_up(d: IngredientDictionary) -> None:
    got = line(
        d,
        "milk or heavy cream",
        1,
        "cup",
        have(d, "milk", 0.5, "cup"),
        have(d, "whole milk", 0.5, "cup"),
        have(d, "heavy cream", 0.5, "cup"),
    )
    assert got.status == "available"
    assert got.reason.startswith("Together your 2 pantry entries")


# --- 2. photo estimates never make a line available ---------------------------------------


def test_estimated_amount_caps_at_uncertain(d: IngredientDictionary) -> None:
    got = line(d, "egg", 4, None, have(d, "eggs", 12, estimate=True))
    assert got.status == "uncertain"
    assert "estimate from a photo" in got.reason
    assert got.reason.startswith("You have 12 eggs; the recipe needs 4.")


def test_same_amount_typed_in_is_available(d: IngredientDictionary) -> None:
    assert line(d, "egg", 4, None, have(d, "eggs", 12)).status == "available"


def test_estimates_are_excluded_from_sums(d: IngredientDictionary) -> None:
    got = line(d, "egg", 4, None, have(d, "eggs", 3), have(d, "eggs", 3, estimate=True))
    assert got.status == "uncertain"


def test_a_typed_entry_beats_an_estimated_duplicate(d: IngredientDictionary) -> None:
    got = line(d, "egg", 4, None, have(d, "eggs", 12, estimate=True), have(d, "eggs", 6))
    assert got.status == "available"


def test_qualitative_line_only_needs_presence_even_if_estimated(d: IngredientDictionary) -> None:
    # The estimate is about the amount; a line with no amount is satisfied by presence.
    assert line(d, "salt", None, None, have(d, "salt", 1, "count", estimate=True)).status == (
        "available"
    )


# --- 9. normalisation ---------------------------------------------------------------------


@pytest.mark.parametrize(
    "text", ["clove garlic", "cloves garlic", "garlic cloves", "cloves of garlic", "Garlic Clove"]
)
def test_garlic_clove_spellings(text: str, d: IngredientDictionary) -> None:
    assert normalize(text, d).key == "garlic"


def test_egg_whites_and_yolks_are_distinct_from_eggs(d: IngredientDictionary) -> None:
    assert normalize("egg whites", d).key == "egg white"
    assert normalize("egg yolks", d).key == "egg yolk"
    assert len({normalize(t, d).key for t in ("eggs", "egg whites", "egg yolks")}) == 3
    entry = normalize("egg yolk", d).entry
    assert entry is not None and "egg" in entry.allergens
    assert line(d, "egg yolk", 2, None, have(d, "eggs", 12)).status == "missing"


@pytest.mark.parametrize(
    "text", ["low-sodium soy sauce", "Low sodium soy sauce", "reduced-sodium soy sauce"]
)
def test_low_sodium_soy_sauce_is_soy_sauce_with_the_modifier_kept(
    text: str, d: IngredientDictionary
) -> None:
    n = normalize(text, d)
    assert n.key == "soy sauce"
    assert n.modifiers and next(iter(n.modifiers)).endswith("-sodium")
    assert normalize("soy sauce", d).modifiers == frozenset()


def test_or_inside_parentheses_is_not_split() -> None:
    assert alternatives("roasted seaweed (gim or nori)") == ["roasted seaweed (gim or nori)"]
    assert alternatives("spam or bacon (diced)") == ["spam", "bacon (diced)"]


def test_salt_and_pepper_is_two_items(d: IngredientDictionary) -> None:
    assert conjuncts("salt and pepper", d) == ["salt", "pepper"]
    assert conjuncts("Salt & pepper", d) == ["salt", "pepper"]
    assert conjuncts("macaroni and cheese", d) == ["macaroni and cheese"]  # unknown part
    assert conjuncts("gochujang", d) == ["gochujang"]
    assert conjuncts("sesame seeds (black and white)", d) == ["sesame seeds (black and white)"]


def test_salt_and_pepper_needs_both(d: IngredientDictionary) -> None:
    salt, pepper = have(d, "kosher salt"), have(d, "pepper")
    assert line(d, "salt and pepper", None, None, salt, pepper).status == "available"
    missing = line(d, "salt and pepper", None, None, salt)
    assert missing.status == "missing"
    assert "pepper" in missing.reason
    # a shared amount can't be split between the parts → never better than uncertain
    assert line(d, "salt and pepper", 1, "tsp", salt, pepper).status == "uncertain"


# --- dietary identity inside parentheses (lead fix after re-review) ---------------------------


@pytest.mark.parametrize(
    "recipe_line",
    ["soy sauce (gluten-free)", "Soy Sauce (Gluten-Free)", "soy sauce (gluten-free, low sodium)"],
)
def test_dietary_identity_in_parentheses_is_kept(d: IngredientDictionary, recipe_line: str) -> None:
    """A recipe's "(gluten-free)" must not be dropped: plain soy sauce is not gluten-free."""
    assert normalize(recipe_line, d).key != normalize("soy sauce", d).key
    assert normalize(recipe_line, d).key == normalize("gluten-free soy sauce", d).key


@pytest.mark.parametrize("recipe_line", ["butter (dairy-free)", "mayonnaise (vegan)"])
def test_unknown_dietary_variants_never_match_the_plain_ingredient(
    d: IngredientDictionary, recipe_line: str
) -> None:
    plain = recipe_line.split(" (")[0]
    assert normalize(recipe_line, d).key != normalize(plain, d).key


def test_preparation_parentheticals_are_still_dropped(d: IngredientDictionary) -> None:
    assert normalize("onion (finely chopped)", d).key == normalize("onion", d).key
