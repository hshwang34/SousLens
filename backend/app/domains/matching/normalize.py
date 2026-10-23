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
from dataclasses import dataclass

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
_PAREN_RE = re.compile(r"\([^)]*\)")


@dataclass(frozen=True, slots=True)
class Normalized:
    key: str
    entry: DictEntry | None
    qualifiers: frozenset[str] = frozenset()

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
    phrase = clean(text)
    if not phrase:
        return Normalized(key="", entry=None)
    if (entry := dictionary.lookup(phrase)) is not None:
        return _hit(entry)

    without_paren = re.sub(r"\s+", " ", _PAREN_RE.sub(" ", phrase)).strip(" ,")
    if without_paren and (entry := dictionary.lookup(without_paren)) is not None:
        return _hit(entry)
    phrase = without_paren or phrase

    words = [w for w in _words(phrase) if w not in DESCRIPTORS] or _words(phrase)
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


def alternatives(name: str) -> list[str]:
    """Recipe names like "spam or bacon" list interchangeable alternatives."""
    parts = [p.strip() for p in re.split(r"\s+or\s+", clean(name)) if p.strip()]
    return parts or [name]
