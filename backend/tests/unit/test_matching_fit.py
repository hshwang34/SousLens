"""Unit tables and recipe fit (FIT-01..03, PRD §12.1-12.2, §17.1). Pure: no database."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from app.domains.matching.dictionary import IngredientDictionary, load_dictionary_file
from app.domains.matching.fit import (
    STALE_AFTER,
    FitResult,
    PantryEntry,
    RecipeIngredient,
    fit,
)
from app.domains.matching.normalize import normalize
from app.domains.matching.units import (
    PANTRY_UNITS,
    canonical_unit,
    convert,
    family,
    format_quantity,
    pantry_unit,
)

FIXTURES_DIR = Path(__file__).resolve().parents[2].parent / "fixtures"
NOW = datetime(2026, 10, 23, 12, 0, tzinfo=UTC)
VERSION_ID = uuid.UUID("00000000-0000-0000-0000-000000000001")


@pytest.fixture(scope="module")
def d() -> IngredientDictionary:
    return load_dictionary_file(FIXTURES_DIR)


def pantry(
    d: IngredientDictionary,
    label: str,
    quantity: float | None = None,
    unit: str | None = None,
    *,
    confirmed: datetime | None = NOW - timedelta(days=1),
) -> PantryEntry:
    return PantryEntry(
        id=uuid.uuid4(),
        raw_label=label,
        normalized_name=normalize(label, d).key,
        quantity=quantity,
        unit=unit,
        last_confirmed_at=confirmed,
    )


def ing(
    name: str,
    quantity: float | None = None,
    unit: str | None = None,
    *,
    optional: bool = False,
    ref: str = "ing-1",
) -> RecipeIngredient:
    return RecipeIngredient(id=ref, name=name, quantity=quantity, unit=unit, optional=optional)


def one(
    d: IngredientDictionary, ingredient: RecipeIngredient, *items: PantryEntry
) -> tuple[FitResult, object]:
    result = fit(VERSION_ID, [ingredient], list(items), d, NOW)
    return result, result.items[0]


# --- units --------------------------------------------------------------------------------


def test_pantry_units_are_exactly_the_contract_list() -> None:
    assert set(PANTRY_UNITS) == {
        "count",
        "g",
        "kg",
        "oz",
        "lb",
        "ml",
        "l",
        "tsp",
        "tbsp",
        "cup",
        "fl_oz",
    }


@pytest.mark.parametrize(
    ("raw", "unit"),
    [
        (None, "count"),
        ("", "count"),
        ("Tablespoons", "tbsp"),
        ("tsp.", "tsp"),
        ("lbs", "lb"),
        ("fl oz", "fl_oz"),
        ("clove", "clove"),
        ("sheet", "sheet"),
    ],
)
def test_canonical_unit(raw: str | None, unit: str) -> None:
    assert canonical_unit(raw) == unit


def test_pantry_unit_rejects_units_outside_the_contract() -> None:
    assert pantry_unit("cups") == "cup"
    assert pantry_unit("bunch") is None
    assert pantry_unit("clove") is None


@pytest.mark.parametrize(
    ("q", "frm", "to", "expected"),
    [
        (1, "cup", "tbsp", 16),
        (3, "tsp", "tbsp", 1),
        (1, "lb", "oz", 16),
        (1, "kg", "g", 1000),
        (1, "l", "ml", 1000),
        (8, "fl_oz", "cup", 1),
        (2, "count", "count", 2),
    ],
)
def test_within_family_conversions(q: float, frm: str, to: str, expected: float) -> None:
    got = convert(q, frm, to)
    assert got is not None and got == pytest.approx(expected, rel=1e-6)


@pytest.mark.parametrize(
    ("frm", "to"),
    [("lb", "cup"), ("g", "ml"), ("oz", "fl_oz"), ("count", "g"), ("clove", "count")],
)
def test_no_cross_family_or_unknown_conversion(frm: str, to: str) -> None:
    assert convert(1, frm, to) is None


def test_families_and_formatting() -> None:
    assert family("oz") == "mass" and family("fl_oz") == "volume" and family("count") == "count"
    assert family("pinch") is None
    assert format_quantity(3.0) == "3"
    assert format_quantity(0.5) == "0.5"
    assert format_quantity(1 / 3) == "0.33"


# --- PRD §17.1 matching cases -------------------------------------------------------------


def test_scallion_recipe_matches_green_onion_pantry(d: IngredientDictionary) -> None:
    _, item = one(d, ing("scallion", 2), pantry(d, "green onions", 6))
    assert item.status == "available"


def test_gochujang_recipe_is_missing_with_only_gochugaru(d: IngredientDictionary) -> None:
    result, item = one(d, ing("gochujang", 3, "tbsp"), pantry(d, "gochugaru", 1, "cup"))
    assert item.status == "missing"
    assert item.pantry_item_id is None
    assert result.can_make is False


def test_one_egg_for_three_is_uncertain_not_available(d: IngredientDictionary) -> None:
    result, item = one(d, ing("eggs", 3), pantry(d, "egg", 1, "count"))
    assert item.status == "uncertain"
    assert item.reason == "You have 1 egg; the recipe needs 3."
    assert item.required.quantity == 3 and item.required.unit == "count"
    assert item.pantry_quantity is not None and item.pantry_quantity.quantity == 1
    assert result.can_make is False


def test_enough_eggs_is_available(d: IngredientDictionary) -> None:
    result, item = one(d, ing("egg", 4), pantry(d, "eggs", 12))
    assert item.status == "available"
    assert item.reason == "You have 12 eggs; the recipe needs 4."
    assert result.can_make is True and result.coverage == 1.0


def test_quantity_unknown_is_uncertain(d: IngredientDictionary) -> None:
    _, item = one(d, ing("honey", 1, "tbsp"), pantry(d, "Honey"))
    assert item.status == "uncertain"
    assert "no amount is recorded" in item.reason
    assert "1 tbsp" in item.reason


def test_optional_missing(d: IngredientDictionary) -> None:
    result, item = one(d, ing("toasted sesame seeds", 1, "tsp", optional=True))
    assert item.status == "optional_missing"
    assert result.can_make is True  # optional items never block
    assert result.counts.optional_missing == 1


def test_required_missing(d: IngredientDictionary) -> None:
    result, item = one(d, ing("garlic", 4, "clove"))
    assert item.status == "missing"
    assert item.reason == "You don't have garlic in your pantry."
    assert result.coverage == 0.0


def test_unit_conversion_within_family_is_available_with_note(d: IngredientDictionary) -> None:
    _, item = one(d, ing("soy sauce", 2, "tbsp"), pantry(d, "soy sauce", 0.5, "cup"))
    assert item.status == "available"
    assert item.conversion_note == "Converted your 0.5 cup to 8 tbsp."


def test_unit_conversion_insufficient_is_uncertain(d: IngredientDictionary) -> None:
    _, item = one(d, ing("spaghetti", 8, "oz"), pantry(d, "spaghetti", 100, "g"))
    assert item.status == "uncertain"
    assert item.conversion_note == "Converted your 100 g to 3.53 oz."


def test_mass_to_volume_is_uncertain_never_guessed(d: IngredientDictionary) -> None:
    _, item = one(d, ing("gochujang", 3, "tbsp"), pantry(d, "gochujang", 1, "lb"))
    assert item.status == "uncertain"
    assert item.conversion_note is not None
    assert "density" in item.conversion_note
    assert "weight (lb)" in item.conversion_note and "volume (tbsp)" in item.conversion_note


def test_recipe_only_unit_is_uncertain_with_note(d: IngredientDictionary) -> None:
    _, item = one(d, ing("garlic", 6, "clove"), pantry(d, "garlic", 2, "count"))
    assert item.status == "uncertain"
    assert item.required.unit == "clove"
    assert item.conversion_note is not None and "clove" in item.conversion_note


def test_qualitative_recipe_item_is_available(d: IngredientDictionary) -> None:
    _, item = one(d, ing("kosher salt"), pantry(d, "salt"))
    assert item.status == "available"
    assert item.required.quantity is None
    assert "doesn't specify an amount" in item.reason


def test_stale_item_is_uncertain_after_14_days(d: IngredientDictionary) -> None:
    old = NOW - STALE_AFTER - timedelta(days=1)
    _, item = one(d, ing("honey"), pantry(d, "honey", confirmed=old))
    assert item.status == "uncertain"
    assert "15 days ago" in item.reason


def test_item_confirmed_exactly_14_days_ago_is_still_fresh(d: IngredientDictionary) -> None:
    _, item = one(d, ing("honey"), pantry(d, "honey", confirmed=NOW - STALE_AFTER))
    assert item.status == "available"


def test_ambiguous_alias_is_uncertain(d: IngredientDictionary) -> None:
    _, item = one(
        d, ing("boneless skinless chicken thighs", 2, "lb"), pantry(d, "chicken", 3, "lb")
    )
    assert item.status == "uncertain"
    assert "may or may not be" in item.reason


def test_ambiguity_is_symmetric(d: IngredientDictionary) -> None:
    _, item = one(d, ing("chili paste", 1, "tbsp"), pantry(d, "gochujang", 1, "cup"))
    assert item.status == "uncertain"


def test_raw_and_cooked_rice_do_not_match(d: IngredientDictionary) -> None:
    _, item = one(d, ing("cooked short-grain rice", 3, "cup"), pantry(d, "jasmine rice", 5, "lb"))
    assert item.status == "missing"


def test_alternatives_match_either(d: IngredientDictionary) -> None:
    _, item = one(d, ing("spam or bacon", 4, "oz", optional=True), pantry(d, "bacon", 12, "oz"))
    assert item.status == "available"


def test_duplicate_entries_can_add_up(d: IngredientDictionary) -> None:
    _, item = one(d, ing("egg", 4), pantry(d, "eggs", 2), pantry(d, "egg", 3))
    assert item.status == "available"
    assert item.reason.startswith("Together your 2 pantry entries have 5 eggs")


def test_best_match_wins_over_a_worse_duplicate(d: IngredientDictionary) -> None:
    good = pantry(d, "honey", 1, "cup", confirmed=NOW - timedelta(days=30))
    fresh = pantry(d, "honey", 2, "cup")
    _, item = one(d, ing("honey", 1, "tbsp"), good, fresh)
    assert item.status == "available"
    assert item.pantry_item_id == fresh.id


def test_stored_normalized_name_still_matches_after_relabel(d: IngredientDictionary) -> None:
    entry = PantryEntry(
        id=uuid.uuid4(),
        raw_label="my special sauce",
        normalized_name="gochujang",
        quantity=None,
        unit=None,
        last_confirmed_at=NOW,
    )
    _, item = one(d, ing("gochujang"), entry)
    assert item.status == "available"


def test_coverage_counts_and_can_make_over_a_whole_recipe(d: IngredientDictionary) -> None:
    ingredients = [
        ing("gochujang", 3, "tbsp", ref="ing-1"),
        ing("soy sauce", 2, "tbsp", ref="ing-2"),
        ing("eggs", 3, ref="ing-3"),
        ing("garlic", 4, "clove", ref="ing-4"),
        ing("sesame seeds", 1, "tsp", optional=True, ref="ing-5"),
    ]
    items = [
        pantry(d, "Gochujang", 1, "cup"),
        pantry(d, "soy sauce", 1, "l"),
        pantry(d, "egg", 1),
    ]
    result = fit(VERSION_ID, ingredients, items, d, NOW)
    assert [i.status for i in result.items] == [
        "available",
        "available",
        "uncertain",
        "missing",
        "optional_missing",
    ]
    assert result.counts.model_dump() == {
        "available": 2,
        "uncertain": 1,
        "missing": 1,
        "optional_missing": 1,
    }
    assert result.coverage == 0.5
    assert result.can_make is False
    assert [i.ingredient_ref for i in result.items] == [f"ing-{n}" for n in range(1, 6)]
    assert all(i.reason.endswith(".") for i in result.items)


def test_no_required_items_can_make(d: IngredientDictionary) -> None:
    result = fit(VERSION_ID, [ing("salt", optional=True)], [], d, NOW)
    assert result.coverage == 1.0 and result.can_make is True


def test_empty_dictionary_still_matches_exact_names() -> None:
    empty = IngredientDictionary.build([])
    entry = PantryEntry(
        id=uuid.uuid4(),
        raw_label="Gochujang",
        normalized_name=normalize("Gochujang", empty).key,
        quantity=None,
        unit=None,
        last_confirmed_at=NOW,
    )
    result = fit(VERSION_ID, [ing("gochujang")], [entry], empty, NOW)
    assert result.items[0].status == "available"
