"""Recipe fit against the confirmed pantry (FIT-01..03, PRD §12.1). Pure: no I/O, ``now`` is
passed in.

Per recipe ingredient:

* ``available``: a pantry item with the same normalised name and enough of it (after a
  within-family conversion), or the recipe gives no amount, and it was confirmed within
  ``STALE_AFTER``;
* ``uncertain``: matched, but the pantry amount is unknown, too small, in an incomparable unit
  (mass↔volume is never converted), confirmed too long ago, or the only match is an ambiguous
  name ("chicken" for chicken thighs);
* ``missing`` / ``optional_missing``: nothing compatible.

``can_make`` is true only when every required ingredient is ``available`` (FIT-03); ``coverage``
is for sorting only and never a promise. Candidate observations never reach this function.
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Literal

from pydantic import BaseModel

from app.domains.matching.dictionary import IngredientDictionary, clean, singularize_word
from app.domains.matching.normalize import Normalized, alternatives, conjuncts, normalize
from app.domains.matching.units import (
    canonical_unit,
    convert,
    display_unit,
    family,
    format_quantity,
)

STALE_AFTER = timedelta(days=14)
_EPSILON = 1e-6

FitStatus = Literal["available", "uncertain", "missing", "optional_missing"]


class Amount(BaseModel):
    quantity: float | None
    unit: str | None


class FitItem(BaseModel):
    ingredient_ref: str
    name: str
    optional: bool
    status: FitStatus
    reason: str
    required: Amount
    pantry_item_id: uuid.UUID | None
    pantry_quantity: Amount | None
    conversion_note: str | None


class FitCounts(BaseModel):
    available: int = 0
    uncertain: int = 0
    missing: int = 0
    optional_missing: int = 0


class FitResult(BaseModel):
    recipe_version_id: uuid.UUID
    can_make: bool
    coverage: float
    counts: FitCounts
    items: list[FitItem]
    computed_at: datetime


@dataclass(frozen=True, slots=True)
class RecipeIngredient:
    id: str
    name: str
    quantity: float | None = None
    unit: str | None = None
    optional: bool = False


@dataclass(frozen=True, slots=True)
class PantryEntry:
    id: uuid.UUID
    raw_label: str
    normalized_name: str
    quantity: float | None
    unit: str | None
    last_confirmed_at: datetime | None
    # A photo count (PRD §8.3, DECISIONS #13): never enough on its own to call a line available.
    quantity_is_estimate: bool = False


@dataclass(frozen=True, slots=True)
class _Pantry:
    item: PantryEntry
    keys: frozenset[str]
    norm: Normalized


@dataclass(frozen=True, slots=True)
class _Assessment:
    status: FitStatus
    reason: str
    note: str | None
    pantry: _Pantry


def _plural(name: str) -> str:
    if name.endswith("s"):
        return name
    if name.endswith("y") and len(name) > 1 and name[-2] not in "aeiou":
        return name[:-1] + "ies"
    if name.endswith(("o", "ch", "sh", "x")):
        return name + "es"
    return name + "s"


def _describe(quantity: float, unit: str, name: str) -> str:
    q = format_quantity(quantity)
    if unit == "count":
        head, _, last = name.rpartition(" ")
        singular = f"{head} {singularize_word(last)}".strip()
        return f"{q} {singular if quantity == 1 else _plural(singular)}"
    return f"{q} {display_unit(unit, quantity)} of {name}"


def _need(quantity: float, unit: str) -> str:
    q = format_quantity(quantity)
    return q if unit == "count" else f"{q} {display_unit(unit, quantity)}"


def _incomparable_note(name: str, have: str, need: str) -> str:
    fam_have, fam_need = family(have), family(need)
    if {fam_have, fam_need} == {"mass", "volume"}:
        return (
            f"Can't convert between weight ({have}) and volume ({need}) for {name} without "
            "knowing its density."
        )
    return (
        f"The recipe measures {name} in {need}; your amount is in {have}, so they can't be "
        "compared."
    )


def _stale_days(item: PantryEntry, now: datetime) -> int | None:
    if item.last_confirmed_at is None:
        return -1
    age = now - item.last_confirmed_at
    return age.days if age > STALE_AFTER else None


ESTIMATE_NOTE = " The amount is an estimate from a photo, so check it."


def _assess(ing: RecipeIngredient, name: str, p: _Pantry, now: datetime) -> _Assessment:
    item = p.item
    status: FitStatus
    note: str | None = None
    if ing.quantity is None:
        status, reason = "available", f"You have {name}; the recipe doesn't specify an amount."
    elif item.quantity is None:
        need = _need(ing.quantity, canonical_unit(ing.unit))
        status = "uncertain"
        reason = f"You have {name}, but no amount is recorded; the recipe needs {need}."
    else:
        need_unit = canonical_unit(ing.unit)
        have_unit = canonical_unit(item.unit)
        have = _describe(item.quantity, have_unit, name)
        need = _need(ing.quantity, need_unit)
        converted = convert(item.quantity, have_unit, need_unit)
        if converted is None:
            status = "uncertain"
            reason = f"You have {have}; the recipe needs {need}."
            note = _incomparable_note(name, have_unit, need_unit)
        else:
            if have_unit != need_unit:
                note = (
                    f"Converted your {format_quantity(item.quantity)} "
                    f"{display_unit(have_unit, item.quantity)} to {format_quantity(converted)} "
                    f"{display_unit(need_unit, converted)}."
                )
            status = "available" if converted + _EPSILON >= ing.quantity else "uncertain"
            reason = f"You have {have}; the recipe needs {need}."
        if item.quantity_is_estimate:
            # DECISIONS #13: an estimated (photo) amount caps the line at uncertain.
            status = "uncertain"
            reason += ESTIMATE_NOTE
    days = _stale_days(item, now)
    if days is not None:
        status = "uncertain"
        if days < 0:
            reason += " It has never been confirmed, so check it's still there."
        else:
            reason += f" You last confirmed it {days} days ago, so check it's still there."
    return _Assessment(status=status, reason=reason, note=note, pantry=p)


def _sum_if_enough(
    ing: RecipeIngredient, name: str, matches: list[_Pantry], now: datetime
) -> _Assessment | None:
    """Several confirmed entries of *one* ingredient (keep_both) may add up to enough.

    ``matches`` must share one normalised key: alternatives of an "X or Y" line are never
    summed together. Stale and estimated amounts never count."""
    if ing.quantity is None or len(matches) < 2:
        return None
    need_unit = canonical_unit(ing.unit)
    total, used = 0.0, []
    for p in matches:
        item = p.item
        if item.quantity is None or item.quantity_is_estimate:
            continue
        if _stale_days(item, now) is not None:
            continue
        converted = convert(item.quantity, canonical_unit(item.unit), need_unit)
        if converted is None:
            continue
        total += converted
        used.append(p)
    if len(used) < 2 or total + _EPSILON < ing.quantity:
        return None
    reason = (
        f"Together your {len(used)} pantry entries have {_describe(total, need_unit, name)}; "
        f"the recipe needs {_need(ing.quantity, need_unit)}."
    )
    return _Assessment(status="available", reason=reason, note=None, pantry=used[0])


_RANK: dict[str, int] = {"available": 0, "uncertain": 1, "optional_missing": 2, "missing": 3}


def _evaluate(
    ing: RecipeIngredient,
    phrase: str,
    pantry: list[_Pantry],
    dictionary: IngredientDictionary,
    now: datetime,
) -> tuple[FitStatus, str, _Assessment | None]:
    """One requirement (possibly "X or Y") against the pantry."""
    name = clean(phrase)
    norms = [normalize(alt, dictionary) for alt in alternatives(phrase)]
    keys = [n.key for n in norms if n.key]
    matches = sorted((p for p in pantry if p.keys & set(keys)), key=_recency, reverse=True)
    if matches:
        assessed = [_assess(ing, name, p, now) for p in matches]
        best = next((a for a in assessed if a.status == "available"), None)
        if best is None:
            for key in keys:  # sum within one alternative only
                group = [p for p in matches if key in p.keys]
                best = _sum_if_enough(ing, name, group, now)
                if best is not None:
                    break
        best = best or assessed[0]
        return best.status, best.reason, best

    key_set = set(keys)
    ambiguous = next(
        (
            p
            for p in pantry
            if key_set & set(p.norm.ambiguous_with)
            or any(set(n.ambiguous_with) & p.keys for n in norms)
        ),
        None,
    )
    if ambiguous is not None:
        reason = (
            f"Your pantry has “{ambiguous.item.raw_label}”, which may or may not be "
            f"{name}; check before you start."
        )
        return "uncertain", reason, _Assessment("uncertain", reason, None, ambiguous)
    if ing.optional:
        return "optional_missing", f"Optional: {name} isn't in your pantry.", None
    return "missing", f"You don't have {name} in your pantry.", None


def _evaluate_line(
    ing: RecipeIngredient,
    pantry: list[_Pantry],
    dictionary: IngredientDictionary,
    now: datetime,
) -> tuple[FitStatus, str, _Assessment | None]:
    parts = conjuncts(ing.name, dictionary)
    if len(parts) == 1:
        return _evaluate(ing, ing.name, pantry, dictionary, now)
    # "salt and pepper": every part is needed; the line is as good as its worst part. A shared
    # amount can't be split between the parts, so each part is checked for presence only.
    part_ing = RecipeIngredient(id=ing.id, name=ing.name, optional=ing.optional)
    results = [_evaluate(part_ing, part, pantry, dictionary, now) for part in parts]
    status = max((r[0] for r in results), key=lambda st: _RANK[st])
    if status == "available" and ing.quantity is not None:
        status = "uncertain"
    reason = " ".join(r[1] for r in results)
    if ing.quantity is not None:
        reason += " The amount is for both together, so check you have enough."
    first = next((r[2] for r in results if r[2] is not None), None)
    return status, reason, first


def _recency(p: _Pantry) -> float:
    return p.item.last_confirmed_at.timestamp() if p.item.last_confirmed_at else 0.0


def _amount_of(item: PantryEntry) -> Amount:
    unit = canonical_unit(item.unit) if item.quantity is not None else item.unit
    return Amount(quantity=item.quantity, unit=unit)


def _required(ing: RecipeIngredient) -> Amount:
    if ing.quantity is None:
        return Amount(quantity=None, unit=ing.unit)
    return Amount(quantity=ing.quantity, unit=canonical_unit(ing.unit))


def fit(
    recipe_version_id: uuid.UUID,
    ingredients: Sequence[RecipeIngredient],
    pantry_items: Sequence[PantryEntry],
    dictionary: IngredientDictionary,
    now: datetime,
) -> FitResult:
    pantry: list[_Pantry] = []
    for item in pantry_items:
        norm = normalize(item.raw_label, dictionary)
        # The stored key and today's dictionary reading both count, so a re-seeded alias
        # never strands an item that was saved earlier.
        keys = frozenset(k for k in (item.normalized_name, norm.key) if k)
        pantry.append(_Pantry(item=item, keys=keys, norm=norm))

    items: list[FitItem] = []
    counts = FitCounts()
    required_total = required_available = 0
    for ing in ingredients:
        status, reason, assessment = _evaluate_line(ing, pantry, dictionary, now)

        if not ing.optional:
            required_total += 1
            required_available += status == "available"
        setattr(counts, status, getattr(counts, status) + 1)
        items.append(
            FitItem(
                ingredient_ref=ing.id,
                name=ing.name,
                optional=ing.optional,
                status=status,
                reason=reason,
                required=_required(ing),
                pantry_item_id=assessment.pantry.item.id if assessment else None,
                pantry_quantity=_amount_of(assessment.pantry.item) if assessment else None,
                conversion_note=assessment.note if assessment else None,
            )
        )

    coverage = 1.0 if required_total == 0 else required_available / required_total
    return FitResult(
        recipe_version_id=recipe_version_id,
        can_make=required_available == required_total,
        coverage=round(coverage, 4),
        counts=counts,
        items=items,
        computed_at=now,
    )
