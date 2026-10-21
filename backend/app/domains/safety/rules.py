"""Deterministic safety precedence (PRD §8.4, CLAUDE.md invariants).

``user_allergy > food_safety_rule > creator_warning > pantry_presence > preference >
culinary_creativity``. Content rules (specific allergen/food-safety checks) arrive in Slice 3;
this module only fixes the ordering and the resolver every rule set will run through.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import IntEnum
from typing import Any


class Precedence(IntEnum):
    """Higher value wins. Never reorder: the numbers are part of the contract."""

    CULINARY_CREATIVITY = 10
    PREFERENCE = 20
    PANTRY_PRESENCE = 30
    CREATOR_WARNING = 40
    FOOD_SAFETY_RULE = 50
    USER_ALLERGY = 60

    def outranks(self, other: Precedence) -> bool:
        return self > other


@dataclass(frozen=True, slots=True)
class RuleVerdict:
    """One rule's opinion about a proposed action (e.g. a substitution)."""

    precedence: Precedence
    allow: bool
    reason: str
    source: str = ""
    details: dict[str, Any] = field(default_factory=dict)


def resolve(verdicts: list[RuleVerdict] | tuple[RuleVerdict, ...]) -> RuleVerdict:
    """Return the winning verdict: highest precedence; ties keep the first one given.

    Among equal precedence a blocking verdict beats an allowing one (safety-conservative).
    """
    if not verdicts:
        raise ValueError("resolve() needs at least one verdict")
    winner = verdicts[0]
    for candidate in verdicts[1:]:
        if candidate.precedence > winner.precedence:
            winner = candidate
        elif candidate.precedence == winner.precedence and not candidate.allow and winner.allow:
            winner = candidate
    return winner
