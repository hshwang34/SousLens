from __future__ import annotations

import pytest

from app.domains.safety.rules import Precedence, RuleVerdict, resolve


def verdict(p: Precedence, allow: bool = True, reason: str = "") -> RuleVerdict:
    return RuleVerdict(precedence=p, allow=allow, reason=reason or p.name.lower())


def test_precedence_order_matches_prd_8_4() -> None:
    ordered = sorted(Precedence, reverse=True)
    assert ordered == [
        Precedence.USER_ALLERGY,
        Precedence.FOOD_SAFETY_RULE,
        Precedence.CREATOR_WARNING,
        Precedence.PANTRY_PRESENCE,
        Precedence.PREFERENCE,
        Precedence.CULINARY_CREATIVITY,
    ]


def test_each_level_outranks_every_lower_level() -> None:
    levels = sorted(Precedence)
    for i, lower in enumerate(levels):
        for higher in levels[i + 1 :]:
            assert higher.outranks(lower)
            assert not lower.outranks(higher)


def test_allergy_beats_everything_regardless_of_input_order() -> None:
    verdicts = [
        verdict(Precedence.CULINARY_CREATIVITY, allow=True),
        verdict(Precedence.PANTRY_PRESENCE, allow=True),
        verdict(Precedence.USER_ALLERGY, allow=False, reason="peanut allergy"),
        verdict(Precedence.FOOD_SAFETY_RULE, allow=False),
        verdict(Precedence.CREATOR_WARNING, allow=True),
    ]
    winner = resolve(verdicts)
    assert winner.precedence is Precedence.USER_ALLERGY
    assert winner.allow is False
    assert resolve(list(reversed(verdicts))) == winner


def test_food_safety_beats_creator_warning_and_pantry() -> None:
    winner = resolve(
        [
            verdict(Precedence.PANTRY_PRESENCE, allow=True),
            verdict(Precedence.CREATOR_WARNING, allow=True),
            verdict(Precedence.FOOD_SAFETY_RULE, allow=False),
        ]
    )
    assert winner.precedence is Precedence.FOOD_SAFETY_RULE


def test_equal_precedence_prefers_blocking_verdict() -> None:
    winner = resolve(
        [
            verdict(Precedence.PREFERENCE, allow=True, reason="likes spicy"),
            verdict(Precedence.PREFERENCE, allow=False, reason="dislikes cilantro"),
        ]
    )
    assert winner.reason == "dislikes cilantro"


def test_equal_precedence_same_outcome_keeps_first() -> None:
    first = verdict(Precedence.CREATOR_WARNING, allow=False, reason="first")
    second = verdict(Precedence.CREATOR_WARNING, allow=False, reason="second")
    assert resolve([first, second]) is first


def test_single_verdict_wins() -> None:
    only = verdict(Precedence.CULINARY_CREATIVITY)
    assert resolve([only]) is only


def test_empty_is_an_error() -> None:
    with pytest.raises(ValueError):
        resolve([])
