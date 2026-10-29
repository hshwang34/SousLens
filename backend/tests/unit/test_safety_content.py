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
        ("gluten", "gluten-free spaghetti", True),  # claims never clear a flag
        ("gluten", "tamari (gluten-free soy sauce)", True),  # tamari: may contain wheat
        ("gluten", "rice vinegar + a pinch of sugar", False),
        ("soy", "tamari", True),
        ("soy", "red miso + gochugaru", True),
        ("soy", "soy milk", True),
        ("soy", "coconut aminos + a pinch of salt", False),
        ("tree nuts", "nut-free almond milk", True),
        ("milk", "lactose-free milk", True),
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


CHICKEN = ["Flip each piece and cook 5 to 6 minutes more.", "boneless skinless chicken thighs"]


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
    assert doneness_notice("I'm done with this step", CHICKEN) is None
    assert doneness_notice("what does finely minced mean?", CHICKEN) is None
    assert doneness_notice("set a timer for 5 minutes", CHICKEN) is None
    assert doneness_notice("how much soy sauce?", CHICKEN) is None


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


# --------------------------------------------------------------------- fix round 1 probe tables

ALLERGY_PROBES = {
    "tree nuts": [
        "pesto",
        "mixed nuts",
        "nut milk",
        "nut butter",
        "amaretto",
        "nougat",
        "gianduja",
        "nuts",
        "pine nuts",
    ],
    "peanut": ["satay", "kung pao chicken", "mixed nuts", "nut butter", "nuts", "chili crisp"],
    "fish": [
        "worcestershire",
        "Lea & Perrins",
        "caesar dressing",
        "nam pla",
        "fish sauce",
        "surimi",
        "haddock",
        "catfish",
        "mahi mahi",
        "snapper",
        "caviar",
        "roe",
        "eel",
    ],
    "shellfish": [
        "calamari",
        "cuttlefish",
        "abalone",
        "XO sauce",
        "belacan",
        "cockles",
        "whelks",
        "snails",
        "kimchi",
        "oyster sauce",
    ],
    "milk": [
        "pesto",
        "grana padano",
        "gouda",
        "brie",
        "gruyère",
        "mascarpone",
        "halloumi",
        "crème fraîche",
        "half and half",
        "custard",
        "burrata",
        "creamer",
        "labneh",
    ],
    "egg": [
        "hollandaise",
        "brioche",
        "albumin",
        "custard",
        "quiche",
        "eggnog",
        "challah",
        "marshmallow",
        "tartar sauce",
    ],
    "soy": [
        "hoisin",
        "teriyaki",
        "ponzu",
        "TVP",
        "yuba",
        "worcestershire",
        "miso",
        "chili crisp",
        "oyster sauce",
    ],
    "gluten": [
        "udon",
        "orzo",
        "farro",
        "crackers",
        "beer",
        "pita",
        "tortilla",
        "naan",
        "wonton wrappers",
        "ramen",
        "tamari",
        "miso",
        "gluten-free pasta",
    ],
    "sesame": ["hummus", "za'atar", "furikake", "halva", "chili crisp", "roasted seaweed"],
}


@pytest.mark.parametrize(
    ("allergy", "text"), [(a, t) for a, texts in ALLERGY_PROBES.items() for t in texts]
)
def test_reviewer_allergy_probes(d: IngredientDictionary, allergy: str, text: str) -> None:
    assert conflicts(text, sensitivities([allergy]), d), (allergy, text)


def test_bare_nuts_is_both_tree_nut_and_peanut(d: IngredientDictionary) -> None:
    assert sorted(conflicts("nuts", sensitivities(["tree nuts", "peanut"]), d)) == [
        "peanut",
        "tree nuts",
    ]
    assert normalize_preference("nuts", d) == "nuts"
    assert conflicts("peanut oil", sensitivities(["nuts"]), d) == ["nuts"]


def test_unknown_allergen_status_is_never_clear(d: IngredientDictionary) -> None:
    from app.domains.safety.content import scan

    for food in (
        "dry sherry",
        "cayenne",
        "pecorino",
        "ham",
        "pancetta",
        "pumpkin seeds",
        "sauerkraut",
        "smoked tofu",
        "coconut aminos",
        "sriracha",
        "nutritional yeast",
        "gluten-free pasta",
    ):
        assert scan(food, d).unknown, food


@pytest.mark.parametrize(
    ("raw", "stored"),
    [
        ("peanut and tree nut allergy", ["peanut", "tree nuts"]),
        ("allergic to shellfish", ["shellfish"]),
        ("Lactose intolerant", ["milk"]),
        ("gluten free", ["gluten"]),
        ("gluten-free", ["gluten"]),
        ("finfish", ["fish"]),
        ("crustacean shellfish", ["shellfish"]),
        ("no dairy", ["milk"]),
        ("eggs, soy", ["egg", "soy"]),
        ("half and half", ["half and half"]),
    ],
)
def test_preference_parsing(d: IngredientDictionary, raw: str, stored: list[str]) -> None:
    from app.domains.safety.content import normalize_preferences_detailed

    keys, unknown = normalize_preferences_detailed([raw], d)
    assert keys == stored and unknown == []


def test_unrecognized_preferences_are_kept_and_matched_per_word(d: IngredientDictionary) -> None:
    from app.domains.safety.content import normalize_preferences_detailed

    keys, unknown = normalize_preferences_detailed(["dragon fruit"], d)
    assert keys == unknown == ["dragon fruit"]
    assert conflicts("dragon fruit salsa", sensitivities(keys), d) == ["dragon fruit"]
    assert conflicts("sliced dragon", sensitivities(keys), d) == ["dragon fruit"]


DONENESS_PROBES = [
    "Is the chicken ready?",
    "Can I eat it yet?",
    "Is it finished?",
    "Can I serve it?",
    "Can I take the pork off the heat?",
    "Is the egg set?",
    "is it good to go",
    "did I cook it long enough",
    "is the center cold",
    "are we good to eat",
    "Is the pork hot enough inside",
    "medium rare yet?",
    "has it reached 165?",
    "is it OK to eat",
    "does it look finished?",
]


@pytest.mark.parametrize("query", DONENESS_PROBES)
def test_doneness_probes_with_high_risk_context(query: str) -> None:
    notice = doneness_notice(query, CHICKEN)
    assert notice and "thermometer" in notice and "USDA" in notice
    assert "it is safe" not in notice.lower()


def test_wide_vocabulary_needs_a_high_risk_food() -> None:
    salad = ["Toss well so every piece is coated.", "persian cucumber", "rice vinegar"]
    assert doneness_notice("Can I serve it?", salad) is None
    assert doneness_notice("Is the chicken done?", salad) is not None  # strict word


def test_raw_tasting_uses_step_context() -> None:
    step = ["Add the chicken pieces to the bowl and toss until every piece is coated."]
    assert is_raw_tasting_request("can I taste the sauce?", step)
    assert not is_raw_tasting_request("can I taste the sauce?", ["Stir the dressing."])


@pytest.mark.parametrize(
    "names",
    [
        {"bread soda"},
        {"self raising flour"},
        {"self-rising flour"},
        {"instant yeast"},
        {"pink salt"},
        {"curing salt #1"},
        {"pasteurized eggs"},
    ],
)
def test_structural_substring_matching(names: set[str]) -> None:
    assert structural_verdict(StructuralContext(frozenset(names), ("Mix.",))) is not None


def test_candidate_food_safety() -> None:
    from app.domains.safety.content import candidate_food_safety_verdict

    assert candidate_food_safety_verdict("raw egg yolk") is not None
    assert candidate_food_safety_verdict("cooked chicken breast") is None


# --- brief 007 fix round 1: model-claim filter ------------------------------------------------


@pytest.mark.parametrize(
    "claim",
    [
        "This is allergen-free and safe for you.",
        "Totally nut-free, no allergy risk.",
        "It will not trigger your allergy.",
        "Gluten-free so fine for celiacs.",
        "Cooked through, safe to eat.",
        "These eggs are not expired.",
        "A hypoallergenic choice.",
    ],
)
def test_model_claims_are_dropped(claim: str) -> None:
    from app.domains.safety.content import strip_model_claims

    kept, dropped = strip_model_claims(f"Adds brightness. {claim}", free_from=True)
    assert (kept, dropped) == ("Adds brightness.", 1)


def test_free_from_only_dropped_when_asked() -> None:
    from app.domains.safety.content import strip_model_claims

    assert strip_model_claims("Use tamari for gluten-free.") == ("Use tamari for gluten-free.", 0)
    assert strip_model_claims("Use tamari for gluten-free.", free_from=True) == ("", 1)
