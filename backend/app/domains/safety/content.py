"""Deterministic safety content rules (brief 005, PRD §8.4, §13.1). Pure: no I/O.

Every rule returns :class:`~app.domains.safety.rules.RuleVerdict` values that go through
:func:`~app.domains.safety.rules.resolve`, so the PRD precedence decides the outcome:
``user_allergy > food_safety_rule > creator_warning > pantry_presence > preference >
culinary_creativity``.

* **Allergy overlap** — a text (a substitution candidate, a recipe ingredient) is scanned for
  dictionary ingredients (longest phrase first, aliases and plurals included) and their allergen
  flags (and a table of compound foods the dictionary lacks); unknown words fall back to
  per-class member words ("cashew" → tree nuts). "Free-from" claims never clear a flag.
* **Food safety** — nothing certifies doneness or safety from a description or an image.
  Doneness questions get a thermometer notice tailored to poultry / ground meat / pork / eggs /
  fish; tasting raw marinade, batter or meat is refused.
* **Not-recommended structural swaps** — leavening, preservation (canning, curing, fermenting)
  and raw-egg emulsions produce ``cannot_substitute``, never a suggestion.

Never "safe for you" wording anywhere: these rules only ever say what we could *not* verify.
"""

from __future__ import annotations

import re
import unicodedata
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

# "<word>-free" claims are recorded (they trigger a label-check note) but NEVER clear a flag:
# "gluten-free spaghetti" still conflicts with a wheat allergy, "nut-free almond milk" with tree
# nuts. Claims are unverifiable and cross-contact is common (fix round 1, item 3).
_FREE_RE = re.compile(r"^([a-z]+)-free$")
_CLAIM_FLAGS: dict[str, frozenset[str]] = {
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

MAX_PHRASE_WORDS = 5


# --------------------------------------------------------------------------- preferences

_SPLIT_RE = re.compile(r"\s*(?:,|;|/|\band\b|&|\+)\s*")
_STRIP_RE = re.compile(
    r"^(?:severe(?:ly)?\s+|mild\s+)?(?:allerg(?:y|ies|ic)\s+(?:to\s+)?|intoleran(?:t|ce)\s+to\s+|"
    r"no\s+|avoid\s+|without\s+|sensitive\s+to\s+)+|"
    r"(?:\s*-?\s*(?:free|allerg(?:y|ies|ic)|intoleran(?:t|ce)|sensitivity|sensitive))+$"
)
PREFERENCE_SYNONYMS = {
    "finfish": "fish",
    "fin fish": "fish",
    "crustacean shellfish": "shellfish",
    "molluscan shellfish": "shellfish",
    "lactose": "milk",
    "cows milk": "milk",
    "cow milk": "milk",
    "dairy products": "milk",
    "tree-nut": "tree nuts",
    "tree-nuts": "tree nuts",
}


def _plain(text: str) -> str:
    """NFKD + strip combining marks, then the dictionary ``clean`` (casefold, quotes, spaces)."""
    decomposed = unicodedata.normalize("NFKD", text)
    stripped = "".join(ch for ch in decomposed if not unicodedata.combining(ch))
    return clean(stripped)


def _known_food(phrase: str, dictionary: IngredientDictionary) -> str | None:
    if phrase in PREFERENCE_SYNONYMS:
        return PREFERENCE_SYNONYMS[phrase]
    if phrase in CLASS_SYNONYMS:
        return CLASS_SYNONYMS[phrase]
    words = phrase.split(" ")
    singular = " ".join([*words[:-1], singularize_word(words[-1])])
    if singular in CLASS_SYNONYMS:
        return CLASS_SYNONYMS[singular]
    if _compound(phrase) is not None:
        return phrase if phrase in KNOWN_COMPOUNDS else singular
    norm = normalize(phrase, dictionary)
    return norm.entry.canonical_name if norm.entry is not None else None


def parse_preference(text: str, dictionary: IngredientDictionary) -> list[tuple[str, bool]]:
    """One typed entry → ``[(stored_key, recognized)]``. "peanut and tree nut allergy" →
    peanut, tree nuts; "lactose intolerant" → milk; "gluten free" → gluten."""
    phrase = _plain(text)
    if not phrase:
        return []
    whole = _STRIP_RE.sub("", phrase).strip()
    if whole and (hit := _known_food(whole, dictionary)) is not None:
        return [(hit, True)]
    out: list[tuple[str, bool]] = []
    for part in _SPLIT_RE.split(phrase):
        part = _STRIP_RE.sub("", part.strip()).strip(" -")
        if not part:
            continue
        hit = _known_food(part, dictionary)
        out.append((hit, True) if hit else (normalize(part, dictionary).key or part, False))
    return out


def normalize_preference(text: str, dictionary: IngredientDictionary) -> str:
    """First stored key for one entry (kept for callers that want a single value)."""
    parsed = parse_preference(text, dictionary)
    return parsed[0][0] if parsed else ""


def normalize_preferences_detailed(
    values: Iterable[str], dictionary: IngredientDictionary
) -> tuple[list[str], list[str]]:
    """Stored keys (deduplicated, in order) and the subset nothing recognised."""
    keys: list[str] = []
    unknown: list[str] = []
    for value in values:
        for key, recognized in parse_preference(value, dictionary):
            if key not in keys:
                keys.append(key)
            if not recognized and key not in unknown:
                unknown.append(key)
    return keys, unknown


def normalize_preferences(values: Iterable[str], dictionary: IngredientDictionary) -> list[str]:
    return normalize_preferences_detailed(values, dictionary)[0]


def unrecognized(labels: Iterable[str], dictionary: IngredientDictionary) -> list[str]:
    return [label for label in labels if _known_food(label, dictionary) is None]


# --------------------------------------------------------------------------- text scanning


@dataclass(frozen=True, slots=True)
class Compound:
    """A food the dictionary does not list. ``known=False``: allergen status unknown (a label
    check is always shown to a user with allergies; never treated as clear)."""

    flags: frozenset[str]
    known: bool = True


def _c(*flags: str, known: bool = True) -> Compound:
    return Compound(frozenset(flags), known)


TN, PN, FI, SH, MI, EG, SO, WH, SE = (
    "tree_nut",
    "peanut",
    "fish",
    "shellfish",
    "milk",
    "egg",
    "soy",
    "wheat",
    "sesame",
)

KNOWN_COMPOUNDS: dict[str, Compound] = {
    # nuts: bare "nut(s)" means BOTH tree nut and peanut
    "nut": _c(TN, PN),
    "nuts": _c(TN, PN),
    "mixed nuts": _c(TN, PN),
    "nut milk": _c(TN),
    "nut butter": _c(TN, PN),
    "pine nut": _c(TN),
    "brazil nut": _c(TN),
    "pesto": _c(TN, MI),
    "amaretto": _c(TN),
    "nougat": _c(TN, EG),
    "gianduja": _c(TN, MI),
    "praline": _c(TN, MI),
    "marzipan": _c(TN),
    "satay": _c(PN),
    "satay sauce": _c(PN, SO),
    "kung pao": _c(PN, SO, WH),
    # fish
    "worcestershire": _c(FI, SO),
    "worcestershire sauce": _c(FI, SO),
    "lea perrins": _c(FI, SO),
    "lea and perrins": _c(FI, SO),
    "caesar dressing": _c(FI, EG, MI),
    "nam pla": _c(FI),
    "surimi": _c(FI, EG, WH),
    "imitation crab": _c(FI, EG, WH),
    "haddock": _c(FI),
    "catfish": _c(FI),
    "mahi mahi": _c(FI),
    "mahi-mahi": _c(FI),
    "snapper": _c(FI),
    "caviar": _c(FI),
    "roe": _c(FI),
    "eel": _c(FI),
    "anchovy": _c(FI),
    "anchovies": _c(FI),
    "dashi": _c(FI),
    "bonito flakes": _c(FI),
    # shellfish (incl. molluscs)
    "calamari": _c(SH),
    "cuttlefish": _c(SH),
    "abalone": _c(SH),
    "xo sauce": _c(SH, FI),
    "belacan": _c(SH),
    "shrimp paste": _c(SH),
    "cockle": _c(SH),
    "whelk": _c(SH),
    "snail": _c(SH),
    "escargot": _c(SH),
    # milk
    "grana padano": _c(MI),
    "gouda": _c(MI),
    "brie": _c(MI),
    "gruyere": _c(MI),
    "mascarpone": _c(MI),
    "halloumi": _c(MI),
    "creme fraiche": _c(MI),
    "half and half": _c(MI),
    "half-and-half": _c(MI),
    "custard": _c(MI, EG),
    "burrata": _c(MI),
    "creamer": _c(MI),
    "coffee creamer": _c(MI),
    "labneh": _c(MI),
    "pecorino": _c(MI, known=False),
    "pecorino romano": _c(MI, known=False),
    # egg
    "hollandaise": _c(EG, MI),
    "brioche": _c(EG, MI, WH),
    "albumin": _c(EG),
    "quiche": _c(EG, MI, WH),
    "eggnog": _c(EG, MI),
    "challah": _c(EG, WH),
    "marshmallow": _c(EG),
    "tartar sauce": _c(EG),
    "aioli": _c(EG),
    # soy
    "hoisin": _c(SO, WH),
    "hoisin sauce": _c(SO, WH),
    "teriyaki": _c(SO, WH),
    "teriyaki sauce": _c(SO, WH),
    "ponzu": _c(SO, WH, FI),
    "tvp": _c(SO),
    "textured vegetable protein": _c(SO),
    "yuba": _c(SO),
    "soy milk": _c(SO),
    "soya milk": _c(SO),
    "smoked tofu": _c(SO, known=False),
    "silken tofu": _c(SO),
    # wheat / gluten
    "udon": _c(WH),
    "orzo": _c(WH),
    "farro": _c(WH),
    "cracker": _c(WH),
    "crackers": _c(WH),
    "beer": _c(WH),
    "pita": _c(WH),
    "tortilla": _c(WH),
    "tortillas": _c(WH),
    "pitas": _c(WH),
    "naan": _c(WH, MI),
    "wonton wrapper": _c(WH, EG),
    "wonton wrappers": _c(WH, EG),
    "ramen": _c(WH),
    "gluten-free pasta": _c(WH, known=False),
    "gluten-free spaghetti": _c(WH, known=False),
    # sesame
    "hummus": _c(SE),
    "za'atar": _c(SE),
    "zaatar": _c(SE),
    "furikake": _c(SE, FI),
    "halva": _c(SE),
    "halvah": _c(SE),
    "tahini": _c(SE),
    "arachis oil": _c(PN),
    "gomasio": _c(SE),
    "frangelico": _c(TN),
    "pad thai sauce": _c(PN, FI, SH),
    "lecithin": _c(SO, known=False),
    "soy lecithin": _c(SO),
    "nuoc cham": _c(FI),
    "nuoc mam": _c(FI),
    "chocolate": _c(MI, known=False),  # milk chocolate; dark often "may contain milk"
    # known allergen-free here (flags none, status known)
    "rice milk": _c(),
    "hemp milk": _c(),
    "pea milk": _c(),
    "coconut cream": _c(),
    "cocoa butter": _c(),
    "apple butter": _c(),
    "cream of tartar": _c(),
    "lime zest": _c(),
    "lemon zest": _c(),
    "orange zest": _c(),
    "lime juice": _c(),
    "lemon juice": _c(),
    "sunflower oil": _c(),
    "avocado oil": _c(),
    "agave syrup": _c(),
    # no dictionary entry and not vetted: UNKNOWN allergen status (item 16C)
    "dry sherry": _c(known=False),
    "sherry": _c(known=False),
    "dry white wine": _c(known=False),
    "white wine": _c(known=False),
    "wine": _c(known=False),
    "cayenne": _c(known=False),
    "ham": _c(known=False),
    "pancetta": _c(known=False),
    "pumpkin seeds": _c(known=False),
    "pepitas": _c(known=False),
    "sauerkraut": _c(known=False),
    "coconut aminos": _c(known=False),
    "sriracha": _c(known=False),
    "nutritional yeast": _c(known=False),
}


def _compound(phrase: str) -> Compound | None:
    hit = KNOWN_COMPOUNDS.get(phrase)
    if hit is None:
        words = phrase.split(" ")
        hit = KNOWN_COMPOUNDS.get(" ".join([*words[:-1], singularize_word(words[-1])]))
    return hit


@dataclass(frozen=True, slots=True)
class Mention:
    entry: DictEntry
    phrase: str
    flags: frozenset[str]
    known: bool = True


@dataclass(frozen=True, slots=True)
class Scan:
    mentions: tuple[Mention, ...]
    uncovered: tuple[str, ...]  # words no known food claimed
    claims: tuple[str, ...]  # "gluten-free" etc.: recorded, never clearing a flag
    text: str  # the plain full text

    @property
    def free_claims(self) -> tuple[str, ...]:
        return self.claims

    @property
    def canonical_names(self) -> frozenset[str]:
        return frozenset(m.entry.canonical_name for m in self.mentions)

    @property
    def unknown(self) -> tuple[str, ...]:
        """Foods whose allergen status we do not know."""
        return tuple(m.phrase for m in self.mentions if not m.known)

    def residue(self) -> str:
        return " ".join(self.uncovered)


_TOKEN_SPLIT = re.compile(r"[^a-z0-9'\-]+")


def _tokens(text: str) -> list[str]:
    plain = _plain(text).replace("&", " and ")
    return [t.strip("'-") for t in _TOKEN_SPLIT.split(plain) if t.strip("'-")]


def _lookup(phrase: str, dictionary: IngredientDictionary) -> tuple[DictEntry, bool] | None:
    compound = _compound(phrase)
    if compound is not None:
        return DictEntry(canonical_name=phrase, allergens=tuple(sorted(compound.flags))), (
            compound.known
        )
    entry = dictionary.lookup(phrase)
    return (entry, True) if entry is not None else None


def scan(text: str, dictionary: IngredientDictionary) -> Scan:
    """Greedy longest-phrase scan over known compounds and the dictionary (aliases, plurals).

    A "<x>-free" token is a claim: it is recorded and skipped, and never part of a match, so
    "gluten-free soy sauce" is read as soy sauce (soy, wheat)."""
    tokens = _tokens(text)
    mentions: list[Mention] = []
    uncovered: list[str] = []
    claims: list[str] = []
    i = 0
    while i < len(tokens):
        if _FREE_RE.match(tokens[i]) and not any(
            _compound(" ".join(tokens[i : i + n])) for n in range(2, MAX_PHRASE_WORDS + 1)
        ):
            claims.append(tokens[i])
            # An unverifiable "<allergen>-free" claim keeps the allergen IN play: "milk-free
            # chocolate" still flags milk, like "dairy-free butter" (fix round 2, item 7).
            claimed = _CLAIM_FLAGS.get(_FREE_RE.match(tokens[i]).group(1))  # type: ignore[union-attr]
            if claimed:
                mentions.append(
                    Mention(DictEntry(canonical_name=tokens[i]), tokens[i], claimed, known=False)
                )
            i += 1
            continue
        hit: tuple[int, DictEntry, bool] | None = None
        for n in range(min(MAX_PHRASE_WORDS, len(tokens) - i), 0, -1):
            window = tokens[i : i + n]
            phrase = " ".join(window)
            if any(_FREE_RE.match(t) for t in window) and _compound(phrase) is None:
                continue  # a claim never joins a dictionary match ("gluten-free soy sauce")
            found = _lookup(phrase, dictionary)
            if found is not None:
                hit = (n, *found)
                break
        if hit is None:
            uncovered.append(tokens[i])
            i += 1
            continue
        n, entry, known = hit
        claims += [t for t in tokens[i : i + n] if _FREE_RE.match(t)]
        mentions.append(
            Mention(entry, " ".join(tokens[i : i + n]), frozenset(entry.allergens), known)
        )
        i += n
    return Scan(tuple(mentions), tuple(uncovered), tuple(claims), " ".join(tokens))


def _has_phrase(haystack: str, phrase: str) -> bool:
    if not phrase:
        return False
    pattern = rf"(?<![a-z0-9]){re.escape(phrase)}(?:s|es)?(?![a-z0-9])"
    return re.search(pattern, haystack) is not None


_FALLBACK_STOP = frozenset(
    {"and", "or", "the", "a", "an", "of", "with", "in", "to", "for", "free", "food", "fruit"}
)


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
    # Unrecognised or plain foods also match per word as a fallback ("dragon fruit" → dragon).
    words = tuple(
        dict.fromkeys(
            [label, *(w for w in label.split(" ") if len(w) > 2 and w not in _FALLBACK_STOP)]
        )
    )
    return Sensitivity(label, names=frozenset({label}), words=words)


def sensitivities(labels: Iterable[str]) -> list[Sensitivity]:
    return [sensitivity(label) for label in labels if label]


def conflicts(
    text: str, terms: Sequence[Sensitivity], dictionary: IngredientDictionary
) -> list[str]:
    """Labels of ``terms`` that ``text`` overlaps (flags, names, member words)."""
    if not terms or not text.strip():
        return []
    found = scan(text, dictionary)
    return [term.label for term in terms if _term_hits(found, term)]


def _term_hits(found: Scan, term: Sensitivity) -> bool:
    for mention in found.mentions:
        if mention.flags & term.flags or mention.entry.canonical_name in term.names:
            return True
    residue = found.residue()
    for phrase in term.exclude:
        residue = re.sub(rf"(?<![a-z0-9]){re.escape(phrase)}(?![a-z0-9])", " ", residue)
    if any(_has_phrase(residue, word) for word in term.words):
        return True
    return any(_has_phrase(found.text, name) for name in term.names)


def allergen_flags(text: str, dictionary: IngredientDictionary) -> frozenset[str]:
    """Every common-allergen flag ``text`` carries (informational warnings, not user-specific)."""
    found = scan(text, dictionary)
    flags: set[str] = set()
    for mention in found.mentions:
        flags |= mention.flags
    words_only = Scan((), found.uncovered, (), "")
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

GUIDANCE_SOURCE = "USDA safe minimum internal temperatures"
DONENESS_NOTICE = (
    "I can't confirm doneness or food safety from a description or a photo. Check with an "
    f"instant-read thermometer against verified food-safety guidance ({GUIDANCE_SOURCE})."
)
CANT_TELL = "I can't tell from a description or photo whether the food has cooked through."
RAW_TASTING_NOTICE = (
    "Don't taste anything that has touched raw meat, poultry, fish or raw egg (marinade, batter, "
    "mixture). Taste only after it has been fully cooked, or set some aside before it touches "
    "the raw ingredient."
)
LABEL_CHECK = (
    "Check every package label: we can't verify ingredients, cross-contact or 'free-from' claims "
    "for your allergy."
)

# Always a doneness / safe-to-eat question, whatever the recipe.
_STRICT_RE = re.compile(
    r"\b(done|doneness|cooked|undercooked|overcooked|safe|unsafe|raw|pink|bloody|runny|"
    r"medium[- ]rare|rare|food poisoning|salmonella|bacteria|e\.? ?coli|listeria|spoiled|"
    r"gone off|internal temp\w*|temperature|thermometer|reached \d+|\d+\s*°?\s*[fc]\b)"
)
# A doneness question only when the step or recipe involves a high-risk food.
_WIDE_RE = re.compile(
    r"\b(ready|eat|eating|edible|serve|serving|set|finished|finish|enough|good to go|"
    r"ok(?:ay)? to|hot inside|cold inside|(?:center|centre|middle|inside) (?:is |still )?"
    r"(?:cold|cool|hot|warm)|(?:cold|cool) in the (?:center|centre|middle)|off the heat|"
    r"take (?:it|them|the \w+) (?:out|off)|pull (?:it|them) (?:out|off)|long enough|"
    r"hot enough|warm enough|cooked enough|cook (?:it |them )?(?:any )?(?:longer|more)|"
    r"still good|(?:is|are|looks?) (?:it|they|this|that|the \w+)? ?(?:still )?"
    r"(?:ok|okay|alright|all right|good|fine)|how (?:much |many )?(?:more |longer)\b.*\buntil)\b"
)
# "set a timer" is a timer request, not "is the egg set?".
_TIMER_SET_RE = re.compile(r"\bset (?:a |the |an )?(?:\d+[- ]\w+ )?(?:timer|alarm|reminder)\b")
_PROGRESS_TALK_RE = re.compile(r"\b(i'?m|i am|we'?re|we are) done\b|\bdone with\b")
# Exempt only "what does <wide word> mean" / "what is <wide word>" / "define <wide word>": the
# defined term must BE the wide vocabulary word (security review, fix round 2). Anything longer
# ("what is the internal temp of chicken when it's ready") is not a definition.
_WIDE_WORDS = (
    r"(?:ready|eat|eating|edible|serve|serving|set|finished|finish|enough|good to go|"
    r"off the heat|long enough|hot enough|cooked enough)"
)
_DEFINITION_RE = re.compile(
    r"^\s*(?:what does ['\"]?"
    + _WIDE_WORDS
    + r"['\"]? mean|what is (?:a |an |the )?['\"]?"
    + _WIDE_WORDS
    + r"['\"]?|define ['\"]?"
    + _WIDE_WORDS
    + r"['\"]?|meaning of ['\"]?"
    + _WIDE_WORDS
    + r"['\"]?)\s*[?.!]?\s*$"
)
# Strong verbs refuse whenever the step / recipe involves a raw high-risk food; weak verbs
# ("eat", "bite", "dip", "try") only when the query also names a raw mixture.
_TASTE_RE = re.compile(r"\b(taste|tasting|lick|licking|sample|sampling|nibble|sip)\b")
_WEAK_TASTE_RE = re.compile(r"\b(eat|bite|dip|dipping|try|have a (?:bite|taste|lick|spoon))\b")
_RAW_MIXTURE_RE = re.compile(r"\b(raw|uncooked|marinade|marinating|batter|dough)\b")
_RAW_CONTEXT_RE = re.compile(
    r"\b(raw|marinade|marinated|marinating|batter|dough|uncooked|mixture)\b"
)

POULTRY = frozenset(
    {
        "chicken",
        "turkey",
        "duck",
        "poultry",
        "hen",
        "goose",
        "quail",
        "thigh",
        "thighs",
        "breast",
        "breasts",
        "drumstick",
        "drumsticks",
        "wing",
        "wings",
    }
)
GROUND = frozenset({"ground", "minced", "mince", "burger", "meatball", "meatballs", "sausage"})
PORK = frozenset({"pork", "ham", "bacon", "spam"})
BEEF = frozenset(
    {
        "beef",
        "steak",
        "steaks",
        "lamb",
        "veal",
        "mutton",
        "brisket",
        "rib",
        "ribs",
        "fillet",
        "fillets",
        "filet",
        "loin",
        "tenderloin",
        "cutlet",
        "cutlets",
        "meat",
    }
)
EGGS = frozenset({"egg", "eggs", "yolk", "yolks"})
SEAFOOD = frozenset(_FISH_WORDS + _SHELLFISH_WORDS) | {
    "prawns",
    "shrimps",
    "mussels",
    "clams",
    "scallops",
    "oysters",
    "tails",
    "claws",
    "steaks",
    "fillets",
    "calamari",
}
RICE = frozenset({"rice"})

GUIDANCE = {
    "poultry": "poultry 165°F (74°C) in the thickest part",
    "ground": "ground meat 160°F (71°C)",
    "pork": "whole cuts of pork, beef or lamb 145°F (63°C) plus a 3-minute rest",
    "egg": "eggs until white and yolk are firm, or 160°F (71°C) for egg dishes",
    "seafood": "fish 145°F (63°C) or until it flakes; shellfish until the flesh is opaque",
    "rice": "cooked rice kept hot above 140°F (60°C), or chilled within 1 hour and reheated "
    "until steaming hot",
}


_NOT_RICE_RE = re.compile(r"\brice (vinegar|wine|noodles?|paper|milk|flour|cakes?|crackers?)\b")


def protein_kinds(texts: Iterable[str]) -> list[str]:
    words: set[str] = set()
    for t in texts:
        words |= set(_tokens(_NOT_RICE_RE.sub(" ", _plain(t))))
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
    if words & RICE:
        kinds.append("rice")
    return kinds


def thermometer_guidance(texts: Iterable[str]) -> str | None:
    kinds = [k for k in protein_kinds(texts) if k != "rice"] or protein_kinds(texts)
    if not kinds:
        return None
    return "Use an instant-read thermometer: " + "; ".join(GUIDANCE[k] for k in kinds) + "."


def _pure_definition(q: str) -> bool:
    """Only "what does <wide word> mean"-style queries exempt the wide vocabulary, and never
    when the query also names a high-risk food. Navigation never exempts anything: "move on, is
    the chicken ready" is a doneness question."""
    if [k for k in protein_kinds([q]) if k != "rice"]:
        return False
    return _DEFINITION_RE.search(q) is not None


def is_doneness_question(query: str, context: Iterable[str] = ()) -> bool:
    """ "Is the chicken done?" always. "Is it ready?" / "Can I serve it?" when the step or recipe
    involves a high-risk food. "I'm done with this step", "set a timer", "what does X mean" no."""
    q = _PROGRESS_TALK_RE.sub(" ", _plain(query))
    if _STRICT_RE.search(q) is not None:
        # The definition exemption never overrides a strict word: "what does 'done' mean, is my
        # chicken done?" is a doneness question (security review of bab9b53).
        return True
    if _pure_definition(q):
        return False
    q = _TIMER_SET_RE.sub(" ", q)
    return _WIDE_RE.search(q) is not None and bool(protein_kinds([q, *context]))


_TEMP_QUESTION_RE = re.compile(
    r"\b(safe|minimum|internal|right|correct|target|proper|what)\b.{0,30}\btemp(erature)?s?\b|"
    r"\btemp(erature)?s?\b.{0,30}\b(safe|done|cooked)\b|\bhow hot\b"
)


def is_temperature_question(query: str) -> bool:
    return _TEMP_QUESTION_RE.search(_plain(query)) is not None


def temperature_table(query: str, context: Iterable[str] = ()) -> str:
    """Our own verified table (USDA safe minimum internal temperatures), never model text.
    The foods in the query / step / recipe first; the whole table when none is known."""
    kinds = [k for k in protein_kinds([query, *context])] or list(GUIDANCE)
    rows = "; ".join(GUIDANCE[k] for k in kinds)
    return (
        f"Verified safe minimum internal temperatures ({GUIDANCE_SOURCE}): {rows}. Measure in "
        "the thickest part with an instant-read thermometer."
    )


def doneness_notice(query: str, context: Iterable[str] = ()) -> str | None:
    """The fixed notice for any doneness / safety question; never a certification."""
    ctx = list(context)
    if not is_doneness_question(query, ctx):
        return None
    guidance = thermometer_guidance([query, *ctx])
    return f"{DONENESS_NOTICE} {guidance}" if guidance else DONENESS_NOTICE


def is_raw_tasting_request(query: str, context: Iterable[str] = ()) -> bool:
    """ "Can I taste the marinade / sauce?" while the step or recipe involves raw meat, poultry,
    fish or egg (``context`` = the step texts so far plus the recipe's ingredient names), or
    "can I have a bite of the marinade" / "can I eat the raw batter"."""
    q = _plain(query)
    raw_kinds = [k for k in protein_kinds([q, *context]) if k != "rice"]
    raw_mixture = _RAW_MIXTURE_RE.search(q) is not None  # marinade / batter / dough / raw
    if _TASTE_RE.search(q):
        return bool(raw_kinds) or raw_mixture
    if _WEAK_TASTE_RE.search(q) and _RAW_CONTEXT_RE.search(q):
        return bool(raw_kinds) or raw_mixture
    return False


def food_safety_verdict(query: str, context: Iterable[str] = ()) -> RuleVerdict | None:
    ctx = list(context)
    if is_raw_tasting_request(query, ctx):
        return RuleVerdict(
            Precedence.FOOD_SAFETY_RULE, False, RAW_TASTING_NOTICE, source="raw_tasting"
        )
    notice = doneness_notice(query, ctx)
    if notice:
        return RuleVerdict(Precedence.FOOD_SAFETY_RULE, True, notice, source="doneness")
    return None


def candidate_safety_risks(candidate: str) -> list[str]:
    """Risks attached to a substitute that is itself a high-risk protein."""
    guidance = thermometer_guidance([candidate])
    if guidance is None or protein_kinds([candidate]) == ["rice"]:
        return []
    return [f"Cook it through. {guidance}"]


# --------------------------------------------------------------------------- structural swaps

_LEAVENING_RE = re.compile(
    r"(baking soda|baking powder|bread soda|bicarbonate|bicarb|yeast|self[- ]?ris(ing|en)|"
    r"self[- ]?rais(ing|ed)|sourdough starter|cream of tartar|leaven)"
)
_ALWAYS_PRESERVATION_RE = re.compile(
    r"(curing|cure #?\d|pink salt|prague powder|sodium nitrite|saltpet|insta ?cure|citric acid|"
    r"pectin|canning salt|pickling salt|pickling lime)"
)
_PRESERVATION_TARGET_RE = re.compile(r"(salt|sugar|vinegar|lemon|lime|acid|brine)")
_PRESERVATION_RE = re.compile(
    r"\b(canning|canned at home|home[- ]can\w*|water[- ]bath|pressure[- ]can\w*|cure|curing|"
    r"cured|shelf[- ]stable|preserv\w*|ferment\w*|pickling|lacto|airtight jars?|sterili[sz]ed?)\b"
)
_EGG_TARGET_RE = re.compile(r"\b(egg|eggs|yolks?|whites?|albumen)\b|pasteuri[sz]ed egg")
_RAW_EMULSION_RE = re.compile(
    r"\b(mayonnaise|mayo|aioli|hollandaise|emulsi\w*|caesar|eggnog|mousse|tiramisu|"
    r"raw egg|uncooked egg|meringue|zabaglione|sabayon)\b"
)


@dataclass(frozen=True, slots=True)
class StructuralContext:
    target_names: frozenset[str]  # canonical / cleaned names of the target (with alternatives)
    step_texts: tuple[str, ...]  # instructions of the steps that use the target
    recipe_texts: tuple[str, ...] = field(default_factory=tuple)  # title, notes, warnings


def structural_verdict(ctx: StructuralContext) -> RuleVerdict | None:
    names = " | ".join(_plain(n) for n in ctx.target_names)
    if _LEAVENING_RE.search(names):
        return RuleVerdict(
            Precedence.FOOD_SAFETY_RULE,
            False,
            "Leavening controls how the recipe rises and sets; swapping it is not recommended. "
            "Keep the original or choose another recipe.",
            source="structural_leavening",
        )
    texts = " ".join(_plain(t) for t in (*ctx.step_texts, *ctx.recipe_texts))
    if _ALWAYS_PRESERVATION_RE.search(names) or (
        _PRESERVATION_TARGET_RE.search(names) and _PRESERVATION_RE.search(texts)
    ):
        return RuleVerdict(
            Precedence.FOOD_SAFETY_RULE,
            False,
            "This ingredient preserves the food (canning, curing or fermenting). Salt, acid, "
            "sugar and curing levels keep it safe, so substituting them is not recommended.",
            source="structural_preservation",
        )
    step_text = " ".join(_plain(t) for t in ctx.step_texts)
    if _EGG_TARGET_RE.search(names) and ("pasteuri" in names or _RAW_EMULSION_RE.search(step_text)):
        return RuleVerdict(
            Precedence.FOOD_SAFETY_RULE,
            False,
            "The egg here is eaten uncooked or forms an emulsion; a swap changes both the "
            "structure and the food-safety picture, so it is not recommended.",
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
    names = [_plain(n) for n in target_names if n]
    for warning in warnings:
        w = _plain(warning)
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


_RAW_WORD_RE = re.compile(r"\b(raw|uncooked|undercooked|rare|unpasteuri[sz]ed)\b")


def candidate_food_safety_verdict(candidate: str) -> RuleVerdict | None:
    """A replacement that is itself a raw high-risk food ("raw egg yolk") is never offered."""
    text = _plain(candidate)
    kinds = [k for k in protein_kinds([text]) if k != "rice"]
    if kinds and _RAW_WORD_RE.search(text):
        return RuleVerdict(
            Precedence.FOOD_SAFETY_RULE,
            False,
            "A raw or undercooked high-risk food is not offered as a substitute",
            source="raw_candidate",
        )
    return None


# --------------------------------------------------------------------------- answer post-filter

# Second line of defence (security review of bab9b53): questions the detectors miss still reach
# the model, so every model answer is filtered. Conservative on purpose: a sentence that names a
# doneness / safety / readiness term AND carries any affirmative or verdict word is dropped,
# whatever its phrasing, even next to a deferral to a thermometer.
_SAFETY_TERM_RE = re.compile(
    r"\b(done|doneness|cooked|cook(?:ed)? through|undercooked|overcooked|safe|safely|unsafe|"
    r"ready|edible|eat|eaten|eating|serve|raw|pink|bloody|runny|rare|set|finished|"
    r"temperature|temp|°f|°c|bacteria|salmonella|food poisoning|spoiled)\b"
)
_VERDICT_RE = re.compile(
    r"\b(yes|yeah|yep|yup|sure|absolutely|definitely|certainly|indeed|correct|right|"
    r"is|are|it'?s|its|they'?re|was|were|be|been|looks?|seems?|appears?|sounds?|should|will|"
    r"would|must|can|could|may|fine|ok|okay|good|great|perfect|perfectly|fully|completely|"
    r"totally|thoroughly|properly|enough|now|already|go ahead|done|safe|ready)\b"
)
_BARE_YES_RE = re.compile(
    r"^\W*(yes|yeah|yep|yup|sure|absolutely|definitely|certainly|of course|correct|"
    r"you bet|looks good|all good|good to go)\W*$"
)
_SENTENCE_RE = re.compile(r"(?<=[.!?])\s+")


def mentions_safety_terms(text: str) -> bool:
    return _SAFETY_TERM_RE.search(_plain(text)) is not None


_LEADING_YES_RE = re.compile(
    r"^\s*(?:yes|yeah|yep|yup|sure|absolutely|definitely|certainly|of course|you bet)\b"
    r"[\s,!.:;-]*(?:go ahead\b[\s,!.:;-]*)?(?:and\b\s*)?",
    re.IGNORECASE,
)


def strip_certifications(answer: str, *, high_risk: bool = False) -> tuple[str, int]:
    """Drop every sentence that could certify doneness or safety; return (kept, dropped).

    * Any sentence with a doneness / safety term AND a verdict or affirmative word is dropped,
      deferral phrase or not ("Check with a thermometer, but yes it's done" is dropped).
    * A bare affirmative sentence ("Yes!") is dropped; with a high-risk food in the step or
      recipe, a leading affirmative ("Yep, go ahead and flip it") is cut from its sentence.
    """
    kept: list[str] = []
    dropped = 0
    for sentence in _SENTENCE_RE.split(answer.strip()):
        plain = _plain(sentence)
        if not plain:
            continue
        if _BARE_YES_RE.match(plain) or (
            _SAFETY_TERM_RE.search(plain) and _VERDICT_RE.search(plain)
        ):
            dropped += 1
            continue
        if high_risk and _LEADING_YES_RE.match(sentence):
            rest = _LEADING_YES_RE.sub("", sentence, count=1).strip()
            dropped += 1
            if not rest or not re.search(r"[A-Za-z]", rest):
                continue
            sentence = rest[:1].upper() + rest[1:]
        kept.append(sentence)
    return " ".join(kept).strip(), dropped


def is_high_risk(texts: Iterable[str]) -> bool:
    return bool([k for k in protein_kinds(texts) if k != "rice"])
