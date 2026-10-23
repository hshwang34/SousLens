"""Deterministic safety content rules (brief 005, PRD §8.4, §13.1). Pure: no I/O.

Every rule returns :class:`~app.domains.safety.rules.RuleVerdict` values that go through
:func:`~app.domains.safety.rules.resolve`, so the PRD precedence decides the outcome:
``user_allergy > food_safety_rule > creator_warning > pantry_presence > preference >
culinary_creativity``.

* **Allergy overlap** — a text (a substitution candidate, a recipe ingredient) is scanned for
  dictionary ingredients (longest phrase first, aliases and plurals included) and their allergen
  flags; words the dictionary does not know fall back to per-class member words ("cashew" →
  tree nuts). ``"gluten-free X"`` removes X's wheat flag but is reported as a label-check claim.
* **Food safety** — nothing certifies doneness or safety from a description or an image.
  Doneness questions get a thermometer notice tailored to poultry / ground meat / pork / eggs /
  fish; tasting raw marinade, batter or meat is refused.
* **Not-recommended structural swaps** — leavening, preservation (canning, curing, fermenting)
  and raw-egg emulsions produce ``cannot_substitute``, never a suggestion.

Never "safe for you" wording anywhere: these rules only ever say what we could *not* verify.
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field

from app.domains.matching.dictionary import (
    DictEntry,
    IngredientDictionary,
    clean,
    singularize_word,
)
from app.domains.matching.normalize import normalize
from app.domains.safety.rules import Precedence, RuleVerdict

# --------------------------------------------------------------------------- allergen classes


@dataclass(frozen=True, slots=True)
class AllergenClass:
    """A sensitivity class: the dictionary allergen flags it covers plus member words used when
    the dictionary does not know a word. ``exclude`` lists phrases that contain a member word
    but are not members (plant milks for dairy, "eggplant" is already safe by word boundary)."""

    label: str
    flags: frozenset[str]
    words: tuple[str, ...]
    exclude: tuple[str, ...] = ()


_PLANT_MILKS = (
    "coconut milk",
    "oat milk",
    "almond milk",
    "soy milk",
    "soya milk",
    "rice milk",
    "cashew milk",
    "hemp milk",
    "pea milk",
    "peanut butter",
    "cocoa butter",
    "apple butter",
    "shea butter",
    "cream of tartar",
    "coconut cream",
)

_TREE_NUT_WORDS = (
    "tree nut",
    "almond",
    "walnut",
    "cashew",
    "pecan",
    "pistachio",
    "hazelnut",
    "filbert",
    "macadamia",
    "brazil nut",
    "pine nut",
    "chestnut",
    "praline",
    "marzipan",
    "nutella",
    "frangipane",
)
_PEANUT_WORDS = ("peanut", "groundnut", "monkey nut")
_SHELLFISH_WORDS = (
    "shellfish",
    "shrimp",
    "prawn",
    "crab",
    "lobster",
    "crayfish",
    "crawfish",
    "langoustine",
    "scallop",
    "clam",
    "mussel",
    "oyster",
    "squid",
    "octopus",
    "krill",
)
_FISH_WORDS = (
    "fish",
    "anchovy",
    "anchovies",
    "salmon",
    "tuna",
    "cod",
    "sardine",
    "mackerel",
    "trout",
    "tilapia",
    "halibut",
    "bonito",
    "katsuobushi",
    "dashi",
    "worcestershire",
)

ALLERGEN_CLASSES: dict[str, AllergenClass] = {
    c.label: c
    for c in (
        AllergenClass("peanut", frozenset({"peanut"}), _PEANUT_WORDS),
        AllergenClass("tree nuts", frozenset({"tree_nut"}), _TREE_NUT_WORDS),
        AllergenClass(
            "nuts", frozenset({"tree_nut", "peanut"}), (*_TREE_NUT_WORDS, *_PEANUT_WORDS, "nut")
        ),
        AllergenClass("shellfish", frozenset({"shellfish"}), _SHELLFISH_WORDS),
        AllergenClass("fish", frozenset({"fish"}), _FISH_WORDS),
        AllergenClass(
            "seafood",
            frozenset({"fish", "shellfish"}),
            (*_FISH_WORDS, *_SHELLFISH_WORDS, "seafood"),
        ),
        AllergenClass(
            "milk",
            frozenset({"milk"}),
            (
                "milk",
                "dairy",
                "butter",
                "buttermilk",
                "cream",
                "cheese",
                "yogurt",
                "yoghurt",
                "ghee",
                "whey",
                "casein",
                "curd",
                "kefir",
                "parmesan",
                "pecorino",
                "mozzarella",
                "cheddar",
                "ricotta",
                "feta",
                "paneer",
            ),
            _PLANT_MILKS,
        ),
        AllergenClass(
            "egg",
            frozenset({"egg"}),
            ("egg", "eggs", "yolk", "albumen", "mayonnaise", "mayo", "aioli", "meringue"),
        ),
        AllergenClass(
            "soy",
            frozenset({"soy"}),
            ("soy", "soya", "soybean", "tofu", "edamame", "miso", "tamari", "tempeh", "natto"),
        ),
        AllergenClass(
            "wheat",
            frozenset({"wheat"}),
            (
                "wheat",
                "flour",
                "bread",
                "breadcrumb",
                "panko",
                "pasta",
                "couscous",
                "semolina",
                "seitan",
                "spelt",
                "bulgur",
            ),
        ),
        AllergenClass(
            "gluten",
            frozenset({"wheat"}),
            (
                "gluten",
                "wheat",
                "flour",
                "bread",
                "breadcrumb",
                "panko",
                "pasta",
                "couscous",
                "semolina",
                "seitan",
                "spelt",
                "bulgur",
                "barley",
                "rye",
                "malt",
            ),
        ),
        AllergenClass("sesame", frozenset({"sesame"}), ("sesame", "tahini", "benne")),
        AllergenClass("mustard", frozenset({"mustard"}), ("mustard",)),
    )
}

# What a user may type → class label. Only exact (cleaned) matches: "peanut butter" is an
# ingredient, not the peanut class (it still conflicts with a peanut allergy through its flag).
CLASS_SYNONYMS: dict[str, str] = {
    "peanut": "peanut",
    "peanuts": "peanut",
    "groundnut": "peanut",
    "groundnuts": "peanut",
    "tree nut": "tree nuts",
    "tree nuts": "tree nuts",
    "treenut": "tree nuts",
    "treenuts": "tree nuts",
    "nut": "nuts",
    "nuts": "nuts",
    "shellfish": "shellfish",
    "crustacean": "shellfish",
    "crustaceans": "shellfish",
    "mollusc": "shellfish",
    "molluscs": "shellfish",
    "mollusk": "shellfish",
    "mollusks": "shellfish",
    "fish": "fish",
    "seafood": "seafood",
    "milk": "milk",
    "dairy": "milk",
    "lactose": "milk",
    "cow's milk": "milk",
    "egg": "egg",
    "eggs": "egg",
    "soy": "soy",
    "soya": "soy",
    "soybean": "soy",
    "soybeans": "soy",
    "wheat": "wheat",
    "gluten": "gluten",
    "coeliac": "gluten",
    "celiac": "gluten",
    "sesame": "sesame",
    "sesame seed": "sesame",
    "sesame seeds": "sesame",
    "mustard": "mustard",
}

# "<word>-free" claims → the allergen flags the claim removes from the following ingredient.
_FREE_OF: dict[str, frozenset[str]] = {
    "gluten": frozenset({"wheat"}),
    "wheat": frozenset({"wheat"}),
    "dairy": frozenset({"milk"}),
    "milk": frozenset({"milk"}),
    "lactose": frozenset({"milk"}),
    "egg": frozenset({"egg"}),
    "nut": frozenset({"tree_nut", "peanut"}),
    "peanut": frozenset({"peanut"}),
    "soy": frozenset({"soy"}),
    "sesame": frozenset({"sesame"}),
    "fish": frozenset({"fish"}),
    "shellfish": frozenset({"shellfish"}),
}
_FREE_RE = re.compile(r"^([a-z]+)-free$")

MAX_PHRASE_WORDS = 5


def normalize_preference(text: str, dictionary: IngredientDictionary) -> str:
    """One allergy / avoid entry → its stored form: a class label ("tree nuts"), a dictionary
    canonical name ("peanut butter"), or the conservative cleaned key for unknown foods."""
    phrase = clean(text)
    if not phrase:
        return ""
    if phrase in CLASS_SYNONYMS:
        return CLASS_SYNONYMS[phrase]
    singular = " ".join([*phrase.split(" ")[:-1], singularize_word(phrase.split(" ")[-1])])
    if singular in CLASS_SYNONYMS:
        return CLASS_SYNONYMS[singular]
    return normalize(phrase, dictionary).key or phrase


def normalize_preferences(values: Iterable[str], dictionary: IngredientDictionary) -> list[str]:
    out: list[str] = []
    for value in values:
        key = normalize_preference(value, dictionary)
        if key and key not in out:
            out.append(key)
    return out


# --------------------------------------------------------------------------- text scanning


# Common foods the dictionary does not (yet) list but substitution candidates use. Checked before
# the dictionary so "soy milk" is not read as "soy" (soy sauce alias) + "milk".
KNOWN_COMPOUNDS: dict[str, frozenset[str]] = {
    "soy milk": frozenset({"soy"}),
    "soya milk": frozenset({"soy"}),
    "rice milk": frozenset(),
    "cashew milk": frozenset({"tree_nut"}),
    "hemp milk": frozenset(),
    "pea milk": frozenset(),
    "coconut cream": frozenset(),
    "cocoa butter": frozenset(),
    "apple butter": frozenset(),
    "cream of tartar": frozenset(),
    "nutritional yeast": frozenset(),
    "coconut aminos": frozenset(),
    "miso": frozenset({"soy"}),
    "red miso": frozenset({"soy"}),
    "white miso": frozenset({"soy"}),
    "sriracha": frozenset(),
    "pecorino romano": frozenset({"milk"}),
    "pecorino": frozenset({"milk"}),
    "pancetta": frozenset(),
    "ham": frozenset(),
    "sauerkraut": frozenset(),
    "dry sherry": frozenset(),
    "dry white wine": frozenset(),
    "pumpkin seeds": frozenset(),
    "pepitas": frozenset(),
    "smoked tofu": frozenset({"soy"}),
    "silken tofu": frozenset({"soy"}),
    "cayenne": frozenset(),
    "lime zest": frozenset(),
    "lemon zest": frozenset(),
}


@dataclass(frozen=True, slots=True)
class Mention:
    """A known ingredient found in a text. ``flags`` already has "-free" claims removed."""

    entry: DictEntry
    phrase: str
    flags: frozenset[str]
    free_claim: str | None = None


@dataclass(frozen=True, slots=True)
class Scan:
    mentions: tuple[Mention, ...]
    # Words no known ingredient claimed, each with the allergen flags a preceding "X-free"
    # claim removes from it ("gluten-free pasta" → ("pasta", {"wheat"})).
    uncovered: tuple[tuple[str, frozenset[str]], ...]
    text: str  # the cleaned full text

    @property
    def free_claims(self) -> tuple[str, ...]:
        claims = [m.free_claim for m in self.mentions if m.free_claim]
        claims += [w for w, _ in self.uncovered if _FREE_RE.match(w)]
        return tuple(claims)

    @property
    def canonical_names(self) -> frozenset[str]:
        return frozenset(m.entry.canonical_name for m in self.mentions)

    def residue(self, flags: frozenset[str]) -> str:
        """Uncovered words, minus any a "-free" claim exempts from every one of ``flags``."""
        words = [
            w
            for w, freed in self.uncovered
            if not _FREE_RE.match(w) and not (flags and flags <= freed)
        ]
        return " ".join(words)


_TOKEN_SPLIT = re.compile(r"[^a-z0-9'\-ñé]+")


def _tokens(text: str) -> list[str]:
    return [t.strip("'-") for t in _TOKEN_SPLIT.split(clean(text)) if t.strip("'-")]


def _lookup(phrase: str, dictionary: IngredientDictionary) -> DictEntry | None:
    flags = KNOWN_COMPOUNDS.get(phrase)
    if flags is not None:
        return DictEntry(canonical_name=phrase, allergens=tuple(sorted(flags)))
    return dictionary.lookup(phrase)


def _free_flags(token: str) -> frozenset[str]:
    m = _FREE_RE.match(token)
    return _FREE_OF.get(m.group(1), frozenset()) if m else frozenset()


def scan(text: str, dictionary: IngredientDictionary) -> Scan:
    """Greedy longest-phrase scan over known compounds and the dictionary (aliases, plurals)."""
    tokens = _tokens(text)
    mentions: list[Mention] = []
    uncovered: list[tuple[str, frozenset[str]]] = []
    i = 0
    while i < len(tokens):
        freed = _free_flags(tokens[i - 1]) if i > 0 else frozenset()
        hit: tuple[int, DictEntry] | None = None
        for n in range(min(MAX_PHRASE_WORDS, len(tokens) - i), 0, -1):
            entry = _lookup(" ".join(tokens[i : i + n]), dictionary)
            if entry is not None:
                hit = (n, entry)
                break
        if hit is None:
            uncovered.append((tokens[i], freed))
            i += 1
            continue
        n, entry = hit
        claim = tokens[i - 1] if freed else None
        mentions.append(
            Mention(entry, " ".join(tokens[i : i + n]), frozenset(entry.allergens) - freed, claim)
        )
        i += n
    return Scan(tuple(mentions), tuple(uncovered), " ".join(tokens))


def _has_phrase(haystack: str, phrase: str) -> bool:
    if not phrase:
        return False
    pattern = rf"(?<![a-z0-9]){re.escape(phrase)}(?:s|es)?(?![a-z0-9])"
    return re.search(pattern, haystack) is not None


@dataclass(frozen=True, slots=True)
class Sensitivity:
    """One stored allergy / avoid entry, resolved for matching."""

    label: str
    flags: frozenset[str] = frozenset()
    names: frozenset[str] = frozenset()
    words: tuple[str, ...] = ()
    exclude: tuple[str, ...] = ()


def sensitivity(label: str) -> Sensitivity:
    cls = ALLERGEN_CLASSES.get(label)
    if cls is not None:
        return Sensitivity(label, cls.flags, frozenset(), cls.words, cls.exclude)
    return Sensitivity(label, names=frozenset({label}), words=(label,))


def sensitivities(labels: Iterable[str]) -> list[Sensitivity]:
    return [sensitivity(label) for label in labels if label]


def conflicts(
    text: str, terms: Sequence[Sensitivity], dictionary: IngredientDictionary
) -> list[str]:
    """Labels of ``terms`` that ``text`` overlaps (dictionary flags, names, member words)."""
    if not terms or not text.strip():
        return []
    found = scan(text, dictionary)
    hits: list[str] = []
    for term in terms:
        if _term_hits(found, term):
            hits.append(term.label)
    return hits


def _term_hits(found: Scan, term: Sensitivity) -> bool:
    for mention in found.mentions:
        if mention.flags & term.flags or mention.entry.canonical_name in term.names:
            return True
    residue = found.residue(term.flags)
    for phrase in term.exclude:
        residue = re.sub(rf"(?<![a-z0-9]){re.escape(phrase)}(?![a-z0-9])", " ", residue)
    if any(_has_phrase(residue, word) for word in term.words):
        return True
    # A name-type entry ("kiwi") may also appear inside a dictionary phrase's words.
    return any(_has_phrase(found.text, name) for name in term.names)


def allergen_flags(text: str, dictionary: IngredientDictionary) -> frozenset[str]:
    """Every common-allergen flag ``text`` carries (informational warnings, not user-specific)."""
    found = scan(text, dictionary)
    flags: set[str] = set()
    for mention in found.mentions:
        flags |= mention.flags
    words_only = Scan((), found.uncovered, "")
    for cls in ALLERGEN_CLASSES.values():
        if cls.label in {"nuts", "seafood", "gluten"}:
            continue
        if _term_hits(words_only, sensitivity(cls.label)):
            flags |= cls.flags
    return frozenset(flags)


FLAG_LABELS = {
    "peanut": "peanut",
    "tree_nut": "tree nuts",
    "shellfish": "shellfish",
    "fish": "fish",
    "milk": "milk",
    "egg": "egg",
    "soy": "soy",
    "wheat": "wheat",
    "sesame": "sesame",
    "mustard": "mustard",
}


def allergy_verdict(
    text: str, allergies: Sequence[Sensitivity], dictionary: IngredientDictionary, *, source: str
) -> RuleVerdict | None:
    hits = conflicts(text, allergies, dictionary)
    if not hits:
        return None
    return RuleVerdict(
        precedence=Precedence.USER_ALLERGY,
        allow=False,
        reason=f"contains something on your allergy list ({', '.join(hits)})",
        source=source,
        details={"allergies": hits},
    )


def avoid_verdict(
    text: str, avoid: Sequence[Sensitivity], dictionary: IngredientDictionary, *, source: str
) -> RuleVerdict | None:
    hits = conflicts(text, avoid, dictionary)
    if not hits:
        return None
    return RuleVerdict(
        precedence=Precedence.PREFERENCE,
        allow=False,
        reason=f"uses a food you prefer to avoid ({', '.join(hits)})",
        source=source,
        details={"avoid": hits},
    )


# --------------------------------------------------------------------------- food safety

DONENESS_NOTICE = (
    "I can't confirm doneness or food safety from a description or a photo. Check with an "
    "instant-read thermometer against trusted food-safety guidance."
)
RAW_TASTING_NOTICE = (
    "Don't taste anything that has touched raw meat, poultry, fish or raw egg (marinade, batter, "
    "mixture). Taste only after it has been fully cooked, or set some aside before it touches "
    "the raw ingredient."
)
LABEL_CHECK = (
    "Check every package label: we can't verify ingredients, cross-contact or 'free-from' claims "
    "for your allergy."
)

_DONENESS_RE = re.compile(
    r"\b(done|cooked|undercooked|overcooked|doneness|safe|unsafe|raw|pink|bloody|ready to eat|"
    r"food poisoning|salmonella|bacteria|e\.? ?coli|listeria|spoiled|gone off|still good|"
    r"set yet|runny|internal temp\w*|temperature)\b"
)
_TASTE_RE = re.compile(r"\b(taste|tasting|lick|try|sample|eat|nibble)\b")
_RAW_CONTEXT_RE = re.compile(
    r"\b(raw|marinade|marinated|marinating|batter|dough|uncooked|mixture)\b"
)

POULTRY = frozenset({"chicken", "turkey", "duck", "poultry", "hen", "goose", "quail"})
GROUND = frozenset({"ground", "minced", "mince", "burger", "meatball", "meatballs", "sausage"})
PORK = frozenset({"pork", "ham"})
BEEF = frozenset({"beef", "steak", "lamb", "veal", "mutton"})
EGGS = frozenset({"egg", "eggs", "yolk", "yolks"})
SEAFOOD = frozenset(_FISH_WORDS + _SHELLFISH_WORDS) | {"prawns", "shrimps", "mussels", "clams"}

GUIDANCE = {
    "poultry": "poultry 165°F (74°C) in the thickest part",
    "ground": "ground meat 160°F (71°C)",
    "pork": "whole cuts of pork, beef or lamb 145°F (63°C) plus a 3-minute rest",
    "egg": "eggs until white and yolk are firm, or 160°F (71°C) for egg dishes",
    "seafood": "fish 145°F (63°C) or until it flakes; shellfish until the flesh is opaque",
}


def protein_kinds(texts: Iterable[str]) -> list[str]:
    words: set[str] = set()
    for t in texts:
        words |= set(_tokens(t))
    kinds: list[str] = []
    if words & POULTRY:
        kinds.append("poultry")
    if words & GROUND:
        kinds.append("ground")
    if words & (PORK | BEEF):
        kinds.append("pork")
    if words & EGGS:
        kinds.append("egg")
    if words & SEAFOOD:
        kinds.append("seafood")
    return kinds


def thermometer_guidance(texts: Iterable[str]) -> str | None:
    kinds = protein_kinds(texts)
    if not kinds:
        return None
    return "Use an instant-read thermometer: " + "; ".join(GUIDANCE[k] for k in kinds) + "."


_PROGRESS_TALK_RE = re.compile(r"\b(i'?m|i am|we'?re|we are) done\b|\bdone with\b")


def is_doneness_question(query: str) -> bool:
    """ "Is the chicken done?" yes; "I'm done with this step" no (that is progress talk)."""
    return _DONENESS_RE.search(_PROGRESS_TALK_RE.sub(" ", clean(query))) is not None


def doneness_notice(query: str, context: Iterable[str] = ()) -> str | None:
    """The fixed notice for any doneness / safety question; never a certification."""
    if not is_doneness_question(query):
        return None
    guidance = thermometer_guidance([query, *context])
    return f"{DONENESS_NOTICE} {guidance}" if guidance else DONENESS_NOTICE


def is_raw_tasting_request(query: str, context: Iterable[str] = ()) -> bool:
    """ "Can I taste the marinade?" while raw meat / poultry / fish / egg is involved."""
    q = clean(query)
    if not _TASTE_RE.search(q):
        return False
    if not (_RAW_CONTEXT_RE.search(q) or protein_kinds([q])):
        return False
    return bool(protein_kinds([q, *context])) or "raw" in q


def food_safety_verdict(query: str, context: Iterable[str] = ()) -> RuleVerdict | None:
    ctx = list(context)
    if is_raw_tasting_request(query, ctx):
        return RuleVerdict(
            Precedence.FOOD_SAFETY_RULE, False, RAW_TASTING_NOTICE, source="raw_tasting"
        )
    notice = doneness_notice(query, ctx)
    if notice:
        # Allowed to answer, but the notice is mandatory and nothing is certified.
        return RuleVerdict(Precedence.FOOD_SAFETY_RULE, True, notice, source="doneness")
    return None


def candidate_safety_risks(candidate: str) -> list[str]:
    """Risks attached to a substitute that is itself a high-risk protein."""
    guidance = thermometer_guidance([candidate])
    return [f"Cook it through. {guidance}"] if guidance else []


# --------------------------------------------------------------------------- structural swaps

LEAVENING = frozenset(
    {
        "baking soda",
        "baking powder",
        "yeast",
        "instant yeast",
        "active dry yeast",
        "fresh yeast",
        "cream of tartar",
        "self-raising flour",
        "self-rising flour",
        "sourdough starter",
    }
)
PRESERVATION_TARGETS = frozenset(
    {
        "salt",
        "sugar",
        "rice vinegar",
        "apple cider vinegar",
        "white vinegar",
        "vinegar",
        "lemon juice",
        "lime juice",
        "lemon",
        "lime",
        "curing salt",
        "pink curing salt",
        "citric acid",
        "pectin",
    }
)
_PRESERVATION_RE = re.compile(
    r"\b(canning|canned at home|home[- ]can\w*|water[- ]bath|pressure[- ]can\w*|cure|curing|"
    r"cured|shelf[- ]stable|preserv\w*|ferment\w*|pickling|lacto|airtight jars?|sterili[sz]ed?)\b"
)
EGG_TARGETS = frozenset({"egg", "egg yolk", "egg white"})
_RAW_EMULSION_RE = re.compile(
    r"\b(mayonnaise|mayo|aioli|hollandaise|emulsi\w*|caesar|eggnog|mousse|tiramisu|"
    r"raw egg|uncooked egg)\b"
)


@dataclass(frozen=True, slots=True)
class StructuralContext:
    target_names: frozenset[str]  # canonical / cleaned names of the target (with alternatives)
    step_texts: tuple[str, ...]  # instructions of the steps that use the target
    recipe_texts: tuple[str, ...] = field(default_factory=tuple)  # title, notes, warnings


def structural_verdict(ctx: StructuralContext) -> RuleVerdict | None:
    names = ctx.target_names
    if names & LEAVENING or any(n.endswith("yeast") for n in names):
        return RuleVerdict(
            Precedence.FOOD_SAFETY_RULE,
            False,
            "Leavening controls how the recipe rises and sets; swapping it is not recommended. "
            "Keep the original or choose another recipe.",
            source="structural_leavening",
        )
    texts = " ".join(clean(t) for t in (*ctx.step_texts, *ctx.recipe_texts))
    if names & PRESERVATION_TARGETS and _PRESERVATION_RE.search(texts):
        return RuleVerdict(
            Precedence.FOOD_SAFETY_RULE,
            False,
            "This recipe preserves food (canning, curing or fermenting). Salt, acid and sugar "
            "levels keep it safe, so substituting them is not recommended.",
            source="structural_preservation",
        )
    step_text = " ".join(clean(t) for t in ctx.step_texts)
    if names & EGG_TARGETS and _RAW_EMULSION_RE.search(step_text):
        return RuleVerdict(
            Precedence.FOOD_SAFETY_RULE,
            False,
            "The egg here forms an uncooked emulsion; a swap changes both the structure and the "
            "food-safety picture, so it is not recommended.",
            source="structural_raw_egg",
        )
    return None


_NO_SUB_RE = re.compile(
    r"\b(do not|don't|never|no)\s+(substitut\w*|swap\w*|replace\w*)\b|\bno substitutes?\b"
)


def creator_warning_verdict(
    target_names: Iterable[str], warnings: Iterable[str]
) -> RuleVerdict | None:
    """A creator warning that forbids swapping this ingredient (or all ingredients) wins over
    pantry, preference and AI creativity."""
    names = [n for n in target_names if n]
    for warning in warnings:
        w = clean(warning)
        if not _NO_SUB_RE.search(w):
            continue
        if not names or any(_has_phrase(w, n) for n in names) or "anything" in w:
            return RuleVerdict(
                Precedence.CREATOR_WARNING,
                False,
                f"The creator's warning says not to substitute this: “{warning.strip()}”",
                source="creator_warning",
            )
    return None
