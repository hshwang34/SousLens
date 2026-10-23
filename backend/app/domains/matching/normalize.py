"""Ingredient-name normalisation (PRD §12.1 steps 1-2). Pure.

Order, stopping at the first dictionary hit:

1. clean (trim, NFKC, casefold, collapse whitespace) and look the whole phrase up
   (canonical names, aliases and their plurals: "green onions" → scallion);
2. drop a parenthetical ("roasted seaweed (gim)") and look up again;
3. drop non-identity descriptors (large, ripe, boneless, chopped, …) and look up again;
4. split off identity qualifiers (fresh/dried, raw/cooked, sweetened/unsweetened, ground/whole).
   The base resolves to an entry only if every spoken qualifier is one the entry implies
   ("fresh basil" → basil). Otherwise the qualified canonical is tried ("dried" + basil → dried
   basil), and failing that the key keeps the qualifier ("dried cilantro" ≠ cilantro), so
   qualifiers are never silently dropped;
5. unknown names fall back to a conservative singularisation of the last word.

The resulting ``key`` is the matching key stored as ``pantry_items.normalized_name``.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, replace

from app.domains.matching.dictionary import (
    IDENTITY_QUALIFIERS,
    DictEntry,
    IngredientDictionary,
    clean,
    singularize_word,
)

NAME_KEY_MAX = 120

# Words that describe size, ripeness, cut or prep but never identity. Allergen- or
# identity-bearing words (peanut, almond, toasted, smoked, …) are deliberately absent.
DESCRIPTORS = frozenset(
    {
        "large",
        "small",
        "medium",
        "extra-large",
        "jumbo",
        "big",
        "ripe",
        "organic",
        "free-range",
        "boneless",
        "skinless",
        "bone-in",
        "skin-on",
        "chopped",
        "diced",
        "minced",
        "sliced",
        "grated",
        "peeled",
        "trimmed",
        "frozen",
    }
)
# Non-identity modifiers that are worth keeping (reported, never part of the key): low-sodium
# soy sauce still satisfies "soy sauce", but the caller can show what the user actually has.
MODIFIERS = frozenset(
    {"low-sodium", "reduced-sodium", "less-sodium", "low-salt", "no-salt-added", "lite"}
)
_PAREN_RE = re.compile(r"\([^)]*\)")
_SODIUM_RE = re.compile(r"\b(low|reduced|less) sodium\b")


@dataclass(frozen=True, slots=True)
class Normalized:
    key: str
    entry: DictEntry | None
    qualifiers: frozenset[str] = frozenset()
    modifiers: frozenset[str] = frozenset()

    @property
    def ingredient_id(self):
        return self.entry.id if self.entry is not None else None

    @property
    def ambiguous_with(self) -> tuple[str, ...]:
        return self.entry.ambiguous_with if self.entry is not None else ()


def _hit(entry: DictEntry, qualifiers: frozenset[str] = frozenset()) -> Normalized:
    return Normalized(key=entry.canonical_name, entry=entry, qualifiers=qualifiers)


def _words(text: str) -> list[str]:
    return [w for w in text.split(" ") if w]


def normalize(text: str, dictionary: IngredientDictionary) -> Normalized:
    result = _normalize(text, dictionary)
    modifiers = frozenset(
        w for w in _words(_SODIUM_RE.sub(r"\1-sodium", clean(text))) if w in MODIFIERS
    )
    return replace(result, modifiers=modifiers) if modifiers else result


def _normalize(text: str, dictionary: IngredientDictionary) -> Normalized:
    phrase = clean(text)
    if not phrase:
        return Normalized(key="", entry=None)
    if (entry := dictionary.lookup(phrase)) is not None:
        return _hit(entry)

    without_paren = re.sub(r"\s+", " ", _PAREN_RE.sub(" ", phrase)).strip(" ,")
    if without_paren and (entry := dictionary.lookup(without_paren)) is not None:
        return _hit(entry)
    phrase = without_paren or phrase

    phrase = _SODIUM_RE.sub(r"\1-sodium", phrase)
    skip = DESCRIPTORS | MODIFIERS
    words = [w for w in _words(phrase) if w not in skip] or _words(phrase)
    stripped = " ".join(words)
    if (entry := dictionary.lookup(stripped)) is not None:
        return _hit(entry)

    qualifiers = [w for w in words if w in IDENTITY_QUALIFIERS]
    base_words = [w for w in words if w not in IDENTITY_QUALIFIERS]
    q_set = frozenset(qualifiers)
    if qualifiers and base_words:
        base = " ".join(base_words)
        base_entry = dictionary.lookup(base) or dictionary.lookup(
            " ".join([*base_words[:-1], singularize_word(base_words[-1])])
        )
        if base_entry is not None:
            if q_set <= base_entry.qualifiers:
                return _hit(base_entry, q_set)
            requalified = " ".join([*qualifiers, base_entry.canonical_name])
            if (entry := dictionary.lookup(requalified)) is not None:
                return _hit(entry, q_set)
            return Normalized(key=requalified[:NAME_KEY_MAX], entry=None, qualifiers=q_set)

    if words:
        singular = " ".join([*words[:-1], singularize_word(words[-1])])
        if (entry := dictionary.lookup(singular)) is not None:
            return _hit(entry)
        return Normalized(key=singular[:NAME_KEY_MAX], entry=None, qualifiers=q_set)
    return Normalized(key=stripped[:NAME_KEY_MAX], entry=None, qualifiers=q_set)


def _split_top_level(text: str, separator: re.Pattern[str]) -> list[str]:
    """Split on ``separator`` only outside parentheses ("roasted seaweed (gim or nori)")."""
    parts: list[str] = []
    depth = start = 0
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth = max(0, depth - 1)
        elif depth == 0 and (m := separator.match(text, i)):
            parts.append(text[start:i])
            start = i = m.end()
            continue
        i += 1
    parts.append(text[start:])
    return [p.strip() for p in parts if p.strip()]


_OR_RE = re.compile(r"\s+or\s+")
_AND_RE = re.compile(r"\s+(?:and|&)\s+")


def alternatives(name: str) -> list[str]:
    """Recipe names like "spam or bacon" list interchangeable alternatives."""
    return _split_top_level(clean(name), _OR_RE) or [name]


def conjuncts(name: str, dictionary: IngredientDictionary) -> list[str]:
    """A recipe line naming several required items ("salt and pepper").

    Split only when the whole phrase is not itself a dictionary entry and every part (or each
    of its alternatives) is one, so "macaroni and cheese" or an unknown "X and Y" stays whole.
    """
    phrase = clean(name)
    parts = _split_top_level(phrase, _AND_RE)
    if len(parts) < 2 or normalize(phrase, dictionary).entry is not None:
        return [name]
    for part in parts:
        if any(normalize(alt, dictionary).entry is None for alt in alternatives(part)):
            return [name]
    return parts
