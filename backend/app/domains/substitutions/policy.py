"""The ONE swap policy (brief 005 fix round 1, item 5).

Every path that can put a swap into a session runs through these two functions:
``POST /substitutions/suggest``, ``POST /sessions`` adaptations (including "Use my changes from
last time" variation replays) and the ``approve_adaptation`` command.

* :func:`target_blocker` — may this ingredient be swapped at all? Structural / food-safety
  rules (leavening, preservation, raw egg), a creator warning forbidding swaps, and the vetted
  seed rule's explicit ``no_swap_reason``.
* :func:`candidate_blocker` — may *this* replacement be used? A user allergy, the seed rule's
  ``never`` list (exact candidate names: gochugaru is never a gochujang swap), a raw high-risk
  protein, and (suggestions only) foods the user avoids.

Decisions go through ``domains/safety`` precedence, so the reason shown is always the
highest-ranking one.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from app.domains.matching.dictionary import IngredientDictionary, clean
from app.domains.matching.normalize import normalize
from app.domains.recipes.schemas import IngredientOut, StepOut
from app.domains.safety.content import (
    StructuralContext,
    allergy_verdict,
    avoid_verdict,
    candidate_food_safety_verdict,
    creator_warning_verdict,
    scan,
    structural_verdict,
)
from app.domains.safety.rules import Precedence, RuleVerdict, resolve
from app.domains.substitutions.rules import SeedRule
from app.domains.users.preferences import Profile


@dataclass(frozen=True)
class SwapTarget:
    ingredient: IngredientOut
    names: list[str]  # canonical keys of the line and its alternatives
    steps: list[StepOut]  # steps that use it
    rule: SeedRule | None
    title: str
    dietary_warnings: list[str]  # dietary warnings + creator notes
    recipe_texts: tuple[str, ...] = ()  # title, every step, warnings, notes (structural rules)


def swap_target(
    ingredient: IngredientOut,
    names: list[str],
    steps: list[StepOut],
    rules: dict[str, SeedRule],
    title: str,
    dietary_warnings: list[str],
) -> SwapTarget:
    rule = next((rules[n] for n in names if n in rules), None)
    used = [s for s in steps if ingredient.id in s.ingredient_refs]
    recipe_texts = (
        title,
        *(s.instruction for s in steps),
        *(w for s in steps for w in s.warnings),
        *dietary_warnings,
    )
    return SwapTarget(ingredient, names, used, rule, title, list(dietary_warnings), recipe_texts)


def target_blocker(target: SwapTarget) -> RuleVerdict | None:
    verdicts = [
        v
        for v in (
            structural_verdict(
                StructuralContext(
                    target_names=frozenset([target.ingredient.name, *target.names]),
                    step_texts=tuple(s.instruction for s in target.steps),
                    recipe_texts=target.recipe_texts,
                )
            ),
            creator_warning_verdict(
                [target.ingredient.name, *target.names],
                [w for s in target.steps for w in s.warnings] + target.dietary_warnings,
            ),
            RuleVerdict(
                Precedence.CREATOR_WARNING, False, target.rule.no_swap_reason, "seed_no_swap"
            )
            if target.rule is not None and target.rule.no_swap_reason
            else None,
        )
        if v is not None
    ]
    return resolve(verdicts) if verdicts else None


def is_never(
    candidate: str, target: SwapTarget, dictionary: IngredientDictionary, *, source: str = "ai"
) -> bool:
    """Is ``candidate`` on the rule's ``never`` list?

    * Vetted rule candidates (``source == "rule"``) match by exact name only: the vetted gochujang
      mix *contains* gochugaru and is fine.
    * Anything else (advisor ideas, free-form swaps) matches by phrase, so "gochugaru flakes",
      "extra gochugaru" or "gochugaru powder" are blocked too (fix round 2, item 6)."""
    if target.rule is None or not target.rule.never:
        return False
    never = {clean(n) for n in target.rule.never}
    name = clean(candidate)
    if name in never or normalize(name, dictionary).key in never:
        return True
    if source == "rule":
        return False
    found = scan(name, dictionary)
    if found.canonical_names & never:
        return True
    return any(re.search(rf"(?<![a-z0-9]){re.escape(n)}(?![a-z0-9])", found.text) for n in never)


def candidate_blocker(
    target: SwapTarget,
    candidate: str,
    ratio_or_amount: str | None,
    prof: Profile,
    dictionary: IngredientDictionary,
    *,
    include_avoid: bool,
    source: str,
) -> RuleVerdict | None:
    text = f"{candidate} {ratio_or_amount or ''}"
    verdicts = [
        allergy_verdict(text, prof.allergies, dictionary, source=source),
        candidate_food_safety_verdict(candidate),
        RuleVerdict(
            Precedence.CREATOR_WARNING,
            False,
            f"{candidate} is not a substitute for {target.ingredient.name}",
            source="seed_never",
        )
        if is_never(candidate, target, dictionary, source=source)
        else None,
        avoid_verdict(text, prof.avoid, dictionary, source=source) if include_avoid else None,
    ]
    blocking = [v for v in verdicts if v is not None]
    return resolve(blocking) if blocking else None


def rule_source(candidate: str, target: SwapTarget) -> str:
    """A free-form swap is labelled "Common swap" only when it IS a vetted seed suggestion."""
    if target.rule is None:
        return "ai"
    name = clean(candidate)
    return "rule" if any(clean(s.candidate) == name for s in target.rule.suggestions) else "ai"


def seed_suggestion(candidate: str, target: SwapTarget):  # type: ignore[no-untyped-def]
    if target.rule is None:
        return None
    name = clean(candidate)
    return next((s for s in target.rule.suggestions if clean(s.candidate) == name), None)
