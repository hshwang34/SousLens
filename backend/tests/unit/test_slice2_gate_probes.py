"""QA gate probes for Slice 2 (brief 004): matching edge cases, unit exactness, staleness.

Pure tests (no database). They sit beside the writer's tests and probe what those skip.
"""

from __future__ import annotations

import time
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from app.ai.providers.mock import parse_transcript
from app.domains.matching.dictionary import IngredientDictionary, load_dictionary_file
from app.domains.matching.fit import PantryEntry, RecipeIngredient, fit
from app.domains.matching.normalize import normalize
from app.domains.matching.units import canonical_unit, convert, pantry_unit

FIXTURES_DIR = Path(__file__).resolve().parents[2].parent / "fixtures"
NOW = datetime(2026, 10, 23, 12, 0, tzinfo=UTC)
VID = uuid.UUID("00000000-0000-0000-0000-000000000002")


@pytest.fixture(scope="module")
def d() -> IngredientDictionary:
    return load_dictionary_file(FIXTURES_DIR)


def have(
    d: IngredientDictionary,
    label: str,
    quantity: float | None = None,
    unit: str | None = None,
    *,
    confirmed: datetime | None = NOW - timedelta(hours=1),
) -> PantryEntry:
    return PantryEntry(
        id=uuid.uuid4(),
        raw_label=label,
        normalized_name=normalize(label, d).key,
        quantity=quantity,
        unit=unit,
        last_confirmed_at=confirmed,
    )


def need(name: str, quantity: float | None = None, unit: str | None = None):
    return RecipeIngredient(id="ing-1", name=name, quantity=quantity, unit=unit)


def one(d, pantry, ingredient):  # type: ignore[no-untyped-def]
    return fit(VID, [ingredient], pantry, d, NOW).items[0]


# --- 3. matching edge cases -----------------------------------------------------------------


@pytest.mark.parametrize("word", ["molasses", "hummus", "asparagus", "couscous", "swiss"])
def test_plural_trap_words_are_never_singularised_and_self_match(
    word: str, d: IngredientDictionary
) -> None:
    assert normalize(word, d).key == word
    assert normalize(word.upper(), d).key == word
    assert one(d, [have(d, word)], need(word)).status == "available"


def test_plural_traps_round_trip_through_fit_with_a_regular_plural(d: IngredientDictionary) -> None:
    # "eggs" in the pantry satisfies "egg" in the recipe, and "molasses" does not become "molasse".
    assert one(d, [have(d, "eggs")], need("egg")).status == "available"
    assert one(d, [have(d, "molasses")], need("molasse")).status == "missing"


def test_green_onions_do_not_match_plain_onion_either_way(d: IngredientDictionary) -> None:
    assert one(d, [have(d, "green onions", 6)], need("onion", 1)).status == "missing"
    assert one(d, [have(d, "onions", 6)], need("green onions", 1)).status == "missing"
    assert one(d, [have(d, "onion")], need("scallion")).status == "missing"
    assert normalize("green onions", d).key != normalize("onion", d).key


def test_chicken_thighs_vs_breast_is_never_available(d: IngredientDictionary) -> None:
    got = one(d, [have(d, "chicken thighs", 3, "lb")], need("chicken breast", 3, "lb"))
    assert got.status != "available"
    got = one(d, [have(d, "chicken breast", 3, "lb")], need("chicken thighs", 3, "lb"))
    assert got.status != "available"


def test_generic_chicken_for_a_specific_cut_is_uncertain_not_available(
    d: IngredientDictionary,
) -> None:
    got = one(d, [have(d, "chicken", 3, "lb")], need("chicken thighs", 3, "lb"))
    assert got.status == "uncertain"
    assert "chicken" in got.reason
    # and the reverse: the recipe says "chicken", the pantry has one specific cut
    got = one(d, [have(d, "chicken thighs", 3, "lb")], need("chicken", 3, "lb"))
    assert got.status == "uncertain"


@pytest.mark.parametrize(
    "label",
    [
        "🍯 honey",
        "🥚",
        "蜂蜜",
        "\uff27\uff4f\uff43\uff48\uff55\uff4a\uff41\uff4e\uff47",
        "crème fraîche",
        "a" * 400,
    ],
)
def test_unicode_emoji_and_huge_labels_normalise_stably(
    label: str, d: IngredientDictionary
) -> None:
    first = normalize(label, d)
    assert first.key == normalize(label, d).key  # deterministic
    assert 0 < len(first.key) <= 120
    # an unknown label still matches itself exactly in fit, with no crash
    assert one(d, [have(d, label)], need(label)).status == "available"


def test_fullwidth_gochujang_is_gochujang_and_not_gochugaru(d: IngredientDictionary) -> None:
    assert normalize("\uff27\uff4f\uff43\uff48\uff55\uff4a\uff41\uff4e\uff47", d).key == "gochujang"
    assert one(d, [have(d, "gochugaru")], need("gochujang")).status == "missing"
    assert one(d, [have(d, "gochujang")], need("gochugaru")).status == "missing"


def test_transcript_with_only_filler_yields_no_candidates() -> None:
    for said in ("um uh", "um, uh, hmm", "uhm... like, you know, okay so", "😀😀😀", "..."):
        assert parse_transcript(said) == [], said


def test_transcript_at_the_2000_char_limit_parses_fast_and_deterministically() -> None:
    said = ("honey, " * 400)[:2000]
    assert len(said) == 2000
    start = time.perf_counter()
    first = parse_transcript(said)
    elapsed = time.perf_counter() - start
    assert elapsed < 1.0, f"parse took {elapsed:.2f}s"
    assert first == parse_transcript(said)
    assert [c.canonical_name for c in first] == ["honey"]  # repeats merge

    distinct = ", ".join(f"item{i}" for i in range(300))[:2000]
    start = time.perf_counter()
    parse_transcript(distinct)
    assert time.perf_counter() - start < 1.0

    # pathological: one 2000-char run without separators and a long run of fillers
    for nasty in ("a" * 2000, "um " * 666, "and " * 500, "1 " * 1000, "no wait " * 250):
        start = time.perf_counter()
        parse_transcript(nasty)
        assert time.perf_counter() - start < 1.0, nasty[:12]


def test_emoji_in_a_transcript_is_dropped_never_fabricated_into_items() -> None:
    # Emoji are stripped by the parser: "2 🥚" has no ingredient word, so nothing is invented.
    got = parse_transcript("🍯 honey, 2 🥚")
    assert [(c.raw_label, c.quantity) for c in got] == [("honey", None)]


# --- 4. units ---------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("q", "frm", "to", "expected"),
    [
        (3, "tsp", "tbsp", 1),
        (1, "tbsp", "tsp", 3),
        (16, "tbsp", "cup", 1),
        (48, "tsp", "cup", 1),
        (1, "cup", "tbsp", 16),
        (1, "cup", "tsp", 48),
        (1, "cup", "fl_oz", 8),
        (2, "tbsp", "fl_oz", 1),
        (1000, "ml", "l", 1),
        (16, "oz", "lb", 1),
        (1, "lb", "oz", 16),
        (1000, "g", "kg", 1),
    ],
)
def test_conversions_are_exact_to_nine_places(q: float, frm: str, to: str, expected: float):
    assert convert(q, frm, to) == pytest.approx(expected, abs=1e-9)


@pytest.mark.parametrize(
    ("frm", "to"),
    [("oz", "fl_oz"), ("fl_oz", "oz"), ("lb", "cup"), ("g", "ml"), ("tbsp", "g"), ("count", "g")],
)
def test_mass_and_volume_are_never_converted(frm: str, to: str) -> None:
    assert convert(1, frm, to) is None


def test_oz_and_fl_oz_spellings_stay_in_their_own_family() -> None:
    assert canonical_unit("oz") == "oz" and canonical_unit("ounces") == "oz"
    for spelling in ("fl oz", "fl. oz", "fluid ounce", "fluid ounces", "FL_OZ"):
        assert canonical_unit(spelling) == "fl_oz", spelling
    assert pantry_unit("fl oz") == "fl_oz"


def test_ounces_of_flour_do_not_satisfy_a_cup_and_fl_oz_milk_does_not_satisfy_oz(
    d: IngredientDictionary,
) -> None:
    flour = one(d, [have(d, "flour", 16, "oz")], need("flour", 1, "cup"))
    assert flour.status == "uncertain" and flour.conversion_note
    milk = one(d, [have(d, "milk", 16, "fl_oz")], need("milk", 8, "oz"))
    assert milk.status == "uncertain" and milk.conversion_note
    ok = one(d, [have(d, "milk", 8, "fl_oz")], need("milk", 1, "cup"))
    assert ok.status == "available"


def test_one_lb_of_chicken_for_three_is_uncertain_and_names_both_amounts(
    d: IngredientDictionary,
) -> None:
    got = one(d, [have(d, "chicken", 1, "lb")], need("chicken", 3, "lb"))
    assert got.status == "uncertain"
    assert "1 lb" in got.reason and "3 lb" in got.reason
    assert got.pantry_quantity is not None and got.pantry_quantity.quantity == 1.0
    got = one(d, [have(d, "chicken", 16, "oz")], need("chicken", 3, "lb"))
    assert got.status == "uncertain"  # 16 oz == 1 lb < 3 lb, with a converted note
    assert got.conversion_note and "1 lb" in got.conversion_note
    assert one(d, [have(d, "chicken", 48, "oz")], need("chicken", 3, "lb")).status == "available"


def test_exact_amount_is_available_and_just_under_is_not(d: IngredientDictionary) -> None:
    assert one(d, [have(d, "honey", 3, "tsp")], need("honey", 1, "tbsp")).status == "available"
    assert one(d, [have(d, "honey", 2.9, "tsp")], need("honey", 1, "tbsp")).status == "uncertain"


# --- 5. staleness boundary ----------------------------------------------------------------------


@pytest.mark.parametrize(
    ("age", "status"),
    [
        (timedelta(0), "available"),
        (timedelta(days=13, hours=23), "available"),
        (timedelta(days=14), "available"),  # "more than 14 days" (DECISIONS #11)
        (timedelta(days=14, minutes=1), "uncertain"),
        (timedelta(days=60), "uncertain"),
    ],
)
def test_staleness_boundary_is_exactly_14_days(
    age: timedelta, status: str, d: IngredientDictionary
) -> None:
    got = one(d, [have(d, "honey", 1, "cup", confirmed=NOW - age)], need("honey", 1, "tbsp"))
    assert got.status == status, got.reason
    if status == "uncertain":
        assert "14 days ago" in got.reason or "60 days ago" in got.reason


def test_never_confirmed_item_is_uncertain(d: IngredientDictionary) -> None:
    got = one(d, [have(d, "honey", 1, "cup", confirmed=None)], need("honey"))
    assert got.status == "uncertain"


def test_stale_item_is_not_rescued_by_a_second_stale_entry_adding_up(
    d: IngredientDictionary,
) -> None:
    old = NOW - timedelta(days=30)
    pantry = [have(d, "eggs", 2, confirmed=old), have(d, "eggs", 2, confirmed=old)]
    assert one(d, pantry, need("eggs", 3)).status == "uncertain"
