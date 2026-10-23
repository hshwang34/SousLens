"""The controlled ingredient dictionary (PRD §10 ``ingredients``, §12.1 step 1).

``fixtures/ingredients.json`` is the source; ``make seed`` upserts it into the ``ingredients``
table and the API reads it back from there. Everything here is pure: a dictionary is built from
plain ``DictEntry`` values so unit tests need no database.

Lookup keys are the cleaned canonical name, every alias, and the generated plural forms of each
(dictionary-driven singularisation: "tomatoes" → tomato because "tomato" is an entry; "molasses"
stays molasses because it is an entry itself). An explicit name always wins over a generated
plural, and two entries may never claim the same explicit name (that would collapse distinct
identities such as gochujang and gochugaru).
"""

from __future__ import annotations

import json
import re
import unicodedata
import uuid
from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path

from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import Ingredient

DICTIONARY_FILE = "ingredients.json"

# Qualifiers that change an ingredient's identity (PRD §8.3, §12.1 step 2), with their opposite.
IDENTITY_QUALIFIERS: dict[str, str] = {
    "fresh": "dried",
    "dried": "fresh",
    "raw": "cooked",
    "cooked": "raw",
    "sweetened": "unsweetened",
    "unsweetened": "sweetened",
    "ground": "whole",
    "whole": "ground",
}


class DictionaryFileEntry(BaseModel):
    """One entry of ``fixtures/ingredients.json``."""

    model_config = ConfigDict(extra="forbid")

    canonical_name: str = Field(min_length=1, max_length=120)
    aliases: list[str] = Field(default_factory=list)
    category: str | None = None
    allergens: list[str] = Field(default_factory=list)
    qualifiers: list[str] = Field(default_factory=list)
    ambiguous_with: list[str] = Field(default_factory=list)


class DictionaryFile(BaseModel):
    model_config = ConfigDict(extra="forbid")

    version: int
    note: str | None = None
    ingredients: list[DictionaryFileEntry]


@dataclass(frozen=True, slots=True)
class DictEntry:
    canonical_name: str
    aliases: tuple[str, ...] = ()
    category: str | None = None
    allergens: tuple[str, ...] = ()
    qualifiers: frozenset[str] = frozenset()
    ambiguous_with: tuple[str, ...] = ()
    id: uuid.UUID | None = None


def clean(text: str) -> str:
    """Trim, NFKC, casefold, straighten quotes, collapse whitespace, drop edge punctuation."""
    value = unicodedata.normalize("NFKC", text)
    value = value.replace("\u2019", "'").replace("\u2018", "'").replace("\u2013", "-")
    value = value.casefold()
    value = re.sub(r"\s+", " ", value).strip()
    return value.strip(' .,;:!?"')


def plural_forms(word: str) -> set[str]:
    """Plausible English plurals of a single word (used to build lookup keys only)."""
    forms: set[str] = set()
    if not word or not word[-1].isalpha():
        return forms
    if word.endswith(("s", "x", "z", "ch", "sh")):
        forms.add(word + "es")
    elif word.endswith("y") and len(word) > 1 and word[-2] not in "aeiou":
        forms.add(word[:-1] + "ies")
    elif word.endswith("o"):
        forms.update({word + "s", word + "es"})
    elif word.endswith("fe"):
        forms.update({word[:-2] + "ves", word + "s"})
    elif word.endswith("f"):
        forms.update({word[:-1] + "ves", word + "s"})
    else:
        forms.add(word + "s")
    return forms


def pluralize_phrase(phrase: str) -> set[str]:
    head, _, last = phrase.rpartition(" ")
    return {f"{head} {p}" if head else p for p in plural_forms(last)}


def singularize_word(word: str) -> str:
    """Conservative fallback for words the dictionary does not know."""
    if len(word) > 4 and word.endswith("ies"):
        return word[:-3] + "y"
    if len(word) > 4 and word.endswith("oes"):
        return word[:-2]
    if len(word) > 4 and word.endswith(("ches", "shes", "xes", "sses", "zes")):
        return word[:-2]
    if len(word) > 3 and word.endswith("s") and not word.endswith(("ss", "us", "is", "ys", "as")):
        return word[:-1]
    return word


class DictionaryConflict(ValueError):
    pass


@dataclass
class IngredientDictionary:
    entries: dict[str, DictEntry] = field(default_factory=dict)
    _explicit: dict[str, str] = field(default_factory=dict)
    _generated: dict[str, str] = field(default_factory=dict)

    @classmethod
    def build(cls, entries: Iterable[DictEntry], *, strict: bool = True) -> IngredientDictionary:
        """``strict`` (the fixture file, tests) raises on any conflict; the runtime path keeps
        the first claimant instead so one bad row can never take the API down."""
        d = cls()
        generated: dict[str, set[str]] = {}
        for entry in entries:
            canonical = clean(entry.canonical_name)
            if canonical in d.entries:
                if strict:
                    raise DictionaryConflict(f"duplicate canonical name {canonical!r}")
                continue
            d.entries[canonical] = entry
            for name in (canonical, *(clean(a) for a in entry.aliases)):
                owner = d._explicit.get(name)
                if owner is not None and owner != canonical:
                    if strict:
                        raise DictionaryConflict(
                            f"{name!r} is claimed by {owner!r} and {canonical!r}"
                        )
                    continue
                d._explicit[name] = canonical
                for plural in pluralize_phrase(name):
                    generated.setdefault(plural, set()).add(canonical)
        for key, owners in generated.items():
            if key not in d._explicit and len(owners) == 1:
                d._generated[key] = next(iter(owners))
        for entry in d.entries.values() if strict else ():
            for target in entry.ambiguous_with:
                if clean(target) not in d.entries:
                    raise DictionaryConflict(
                        f"{entry.canonical_name!r} is ambiguous with unknown {target!r}"
                    )
        return d

    def lookup(self, name: str) -> DictEntry | None:
        canonical = self._explicit.get(name) or self._generated.get(name)
        return self.entries.get(canonical) if canonical else None

    def get(self, canonical_name: str) -> DictEntry | None:
        return self.entries.get(clean(canonical_name))

    def __len__(self) -> int:
        return len(self.entries)


def read_dictionary_file(fixtures_dir: Path) -> DictionaryFile:
    path = Path(fixtures_dir) / DICTIONARY_FILE
    return DictionaryFile.model_validate(json.loads(path.read_text(encoding="utf-8")))


def entries_from_file(data: DictionaryFile) -> list[DictEntry]:
    return [
        DictEntry(
            canonical_name=clean(e.canonical_name),
            aliases=tuple(clean(a) for a in e.aliases),
            category=e.category or None,
            allergens=tuple(e.allergens),
            qualifiers=frozenset(e.qualifiers),
            ambiguous_with=tuple(clean(a) for a in e.ambiguous_with),
        )
        for e in data.ingredients
    ]


def load_dictionary_file(fixtures_dir: Path) -> IngredientDictionary:
    return IngredientDictionary.build(entries_from_file(read_dictionary_file(fixtures_dir)))


def entry_from_row(row: Ingredient) -> DictEntry:
    return DictEntry(
        id=row.id,
        canonical_name=row.canonical_name,
        aliases=tuple(row.aliases_json or ()),
        category=row.category,
        allergens=tuple(row.allergen_flags or ()),
        qualifiers=frozenset(row.qualifiers or ()),
        ambiguous_with=tuple(row.ambiguous_with or ()),
    )


async def load_dictionary(session: AsyncSession) -> IngredientDictionary:
    """The seeded dictionary from the database (≈130 rows; read per request, no cache to go
    stale). An unseeded database yields an empty dictionary: matching still works on exact
    names, just without aliases."""
    rows = (
        (await session.execute(select(Ingredient).order_by(Ingredient.canonical_name)))
        .scalars()
        .all()
    )
    return IngredientDictionary.build((entry_from_row(r) for r in rows), strict=False)
