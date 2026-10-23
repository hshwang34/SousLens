"""Brief 005: deterministic safety content rules and their precedence (PRD §8.4, §13.1)."""

from __future__ import annotations

import pytest

from app.domains.matching.dictionary import IngredientDictionary, load_dictionary_file
from app.domains.safety.content import (
    StructuralContext,
    allergen_flags,
    allergy_verdict,
    avoid_verdict,
    conflicts,
    creator_warning_verdict,
    doneness_notice,
    food_safety_verdict,
    is_raw_tasting_request,
    normalize_preference,
    sensitivities,
    structural_verdict,
    thermometer_guidance,
)
from app.domains.safety.rules import Precedence, RuleVerdict, resolve
from tests.conftest import FIXTURES_DIR


@pytest.fixture(scope="module")
def d() -> IngredientDictionary:
    return load_dictionary_file(FIXTURES_DIR)


@pytest.mark.parametrize(
    ("raw", "stored"),
    [
        ("Peanuts", "peanut"),
        ("tree nuts", "tree nuts"),
        ("Tree Nut", "tree nuts"),
        ("shellfish", "shellfish"),
        ("crustaceans", "shellfish"),
        ("gluten", "gluten"),
        ("Dairy", "milk"),
        ("eggs", "egg"),
        ("soya", "soy"),
        ("sesame seeds", "sesame"),
        ("spring onions", "scallion"),
        ("peanut butter", "peanut butter"),
        ("kiwi", "kiwi"),
    ],
)
def test_preference_normalisation(d: IngredientDictionary, raw: str, stored: str) -> None:
    assert normalize_preference(raw, d) == stored


@pytest.mark.parametrize(
    ("allergy", "text", "hit"),
    [
        ("tree nuts", "almond milk", True),
        ("tree nuts", "chopped walnuts", True),
        ("tree nuts", "cashew cream", True),
        ("tree nuts", "coconut milk", False),
        ("tree nuts", "nutmeg", False),
        ("peanut", "peanut oil", True),
        ("peanut", "peanut butter", True),
        ("peanut", "neutral oil", False),
        ("shellfish", "oyster sauce", True),
        ("shellfish", "prawns", True),
        ("fish", "fish sauce", True),
        ("fish", "kimchi", True),  # dictionary flag: kimchi often has fish sauce
        ("gluten", "linguine", True),
        ("gluten", "soy sauce", True),
        ("gluten", "gluten-free spaghetti", False),
        ("gluten", "tamari (gluten-free soy sauce)", False),
        ("gluten", "rice vinegar + a pinch of sugar", False),
        ("soy", "tamari", True),
        ("soy", "red miso + gochugaru", True),
        ("soy", "soy milk", True),
        ("soy", "coconut aminos + a pinch of salt", False),
        ("milk", "butter", True),
        ("milk", "pecorino romano", True),
        ("milk", "oat milk", False),
        ("milk", "coconut milk", False),
        ("milk", "peanut butter", False),
        ("milk", "nutritional yeast", False),
        ("egg", "mayo", True),
        ("egg", "eggplant", False),
        ("sesame", "toasted sesame seeds", True),
        ("kiwi", "kiwi slices", True),
        ("cilantro", "fresh coriander", True),  # name allergy via dictionary alias
    ],
)
def test_allergy_overlap(d: IngredientDictionary, allergy: str, text: str, hit: bool) -> None:
    assert bool(conflicts(text, sensitivities([allergy]), d)) is hit


def test_allergen_flags_are_informational(d: IngredientDictionary) -> None:
    assert allergen_flags("soy sauce", d) == {"soy", "wheat"}
    assert allergen_flags("chives", d) == frozenset()


@pytest.mark.parametrize(
    ("query", "expect"),
    [
        ("Is this chicken definitely cooked?", "165°F"),
        ("is the ground beef safe yet", "160°F"),
        ("is the pork done", "145°F"),
        ("are the eggs set yet?", "firm"),
        ("is it done?", "thermometer"),
    ],
)
def test_doneness_questions_get_thermometer_notice(query: str, expect: str) -> None:
    notice = doneness_notice(query)
    assert notice is not None and expect in notice and "thermometer" in notice
    assert "safe for you" not in notice


def test_progress_talk_is_not_a_doneness_question() -> None:
    assert doneness_notice("I'm done with this step") is None
    assert doneness_notice("what does finely minced mean?") is None


def test_raw_tasting_is_refused() -> None:
    chicken = ["Add the chicken pieces to the bowl", "boneless skinless chicken thighs"]
    assert is_raw_tasting_request("can I taste the marinade?", chicken)
    assert is_raw_tasting_request("is it ok to try the raw cookie dough?")
    assert not is_raw_tasting_request("can I taste the dressing?", ["cucumber", "rice vinegar"])
    verdict = food_safety_verdict("can I taste the marinade?", chicken)
    assert verdict is not None and not verdict.allow
    assert verdict.precedence == Precedence.FOOD_SAFETY_RULE


def test_thermometer_guidance_for_risky_substitutes() -> None:
    assert "165°F" in (thermometer_guidance(["chicken breast"]) or "")
    assert thermometer_guidance(["maple syrup"]) is None


def _ctx(names: set[str], *steps: str) -> StructuralContext:
    return StructuralContext(target_names=frozenset(names), step_texts=steps)


def test_structural_not_recommended() -> None:
    assert structural_verdict(_ctx({"baking soda"}, "Whisk into the flour.")) is not None
    assert structural_verdict(_ctx({"active dry yeast"}, "Proof.")) is not None
    canning = "Process the jars in a water bath canner for 10 minutes."
    assert structural_verdict(_ctx({"white vinegar"}, canning)) is not None
    assert structural_verdict(_ctx({"salt"}, "Toss with the salt and drain.")) is None
    assert structural_verdict(_ctx({"egg yolk"}, "Whisk in oil to make mayonnaise.")) is not None
    assert structural_verdict(_ctx({"egg"}, "Scramble the eggs.")) is None
    verdict = structural_verdict(_ctx({"baking powder"}, "Mix."))
    assert verdict is not None and verdict.precedence == Precedence.FOOD_SAFETY_RULE


def test_creator_warning_forbidding_swap() -> None:
    v = creator_warning_verdict(["honey"], ["Do not substitute the honey; it sets the glaze."])
    assert v is not None and v.precedence == Precedence.CREATOR_WARNING and not v.allow
    assert creator_warning_verdict(["honey"], ["Hot oil spits."]) is None
    assert creator_warning_verdict(["honey"], ["Don't swap the gochujang."]) is None


def test_precedence_order(d: IngredientDictionary) -> None:
    allergy = allergy_verdict("peanut oil", sensitivities(["peanut"]), d, source="t")
    avoid = avoid_verdict("peanut oil", sensitivities(["peanut oil"]), d, source="t")
    assert allergy is not None and avoid is not None
    safety = RuleVerdict(Precedence.FOOD_SAFETY_RULE, False, "safety")
    creator = RuleVerdict(Precedence.CREATOR_WARNING, False, "creator")
    pantry = RuleVerdict(Precedence.PANTRY_PRESENCE, True, "in pantry")
    creative = RuleVerdict(Precedence.CULINARY_CREATIVITY, True, "idea")
    chain = [creative, avoid, pantry, creator, safety, allergy]
    for i in range(len(chain)):
        assert resolve(chain[: i + 1]) is chain[i]  # each level outranks everything below it
    assert resolve([creative, avoid]).allow is False  # a preference beats creativity
    assert resolve([avoid, pantry]) is pantry  # PRD order: pantry presence > preference
    assert resolve([safety, allergy]).precedence == Precedence.USER_ALLERGY
