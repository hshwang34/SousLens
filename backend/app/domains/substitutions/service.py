"""``POST /substitutions/suggest`` (SUB-01/02/05, PRD §8.4, §12.3, brief 005 contract).

Order of decisions, all deterministic except the advisor's ideas:

1. The version must be readable (404) and the ingredient must exist in it (422).
2. Structural / food-safety rules and creator warnings that forbid a swap win outright:
   ``cannot_substitute`` with the rule's reason, and the advisor is never asked.
3. An explicit no-swap seed rule → ``cannot_substitute``.
4. Vetted seed rules first, then the ``SubstitutionAdvisor`` (mock in Slice 3) unless the rule is
   exhaustive. Advisor output is schema-validated (retry once); ``not_recommended`` ideas and
   anything on the rule's ``never`` list (gochugaru for gochujang) are discarded.
5. Every candidate runs through ``domains/safety`` precedence: a user allergy drops it, an
   "avoid" food drops it (as a preference); at most 3 remain, rules first, pantry items first.
6. Each served suggestion is stored (24 h) so ``approve`` can reference it by id.
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta

import pydantic
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.providers.base import (
    SubstitutionAdvisor,
    SubstitutionConstraints,
    SubstitutionRequest,
    SubstitutionResponse,
)
from app.core.errors import (
    AppError,
    ProviderOutputInvalid,
    ProviderUnavailable,
    ValidationError,
)
from app.db.models import PantryItem, Recipe, RecipeVersion, SubstitutionSuggestionRecord, User
from app.domains.matching.dictionary import IngredientDictionary, clean, load_dictionary
from app.domains.matching.normalize import alternatives, normalize
from app.domains.recipes import service as recipes_service
from app.domains.recipes.schemas import IngredientOut, RecipeContent, StepOut
from app.domains.recipes.versions import version_meta
from app.domains.safety.content import (
    FLAG_LABELS,
    LABEL_CHECK,
    StructuralContext,
    allergen_flags,
    allergy_verdict,
    avoid_verdict,
    candidate_safety_risks,
    conflicts,
    creator_warning_verdict,
    scan,
    structural_verdict,
)
from app.domains.safety.rules import Precedence, RuleVerdict, resolve
from app.domains.substitutions.adapt import AdaptationSpec, compose_overlay
from app.domains.substitutions.rules import SeedRule, load_rules
from app.domains.substitutions.schemas import (
    AdjustedStep,
    SuggestIn,
    SuggestionOut,
    SuggestOut,
)
from app.domains.users import preferences

log = logging.getLogger("souslens.substitutions")

MAX_SUGGESTIONS = 3
SUGGESTION_TTL = timedelta(hours=24)
PROVIDER_TIMEOUT_SECONDS = 20.0
NOT_EXACT = "Not an exact match."
_CONF_ORDER = {"high": 0, "medium": 1, "low": 2}


@dataclass
class _Draft:
    source: str
    candidate: str
    kind: str
    ratio_or_amount: str
    rationale: str
    impact_flavor: str
    impact_texture: str
    confidence: str
    risks: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class VersionContext:
    """A readable version, parsed once (shared with sessions)."""

    version_id: uuid.UUID
    recipe_id: uuid.UUID
    title: str
    ingredients: list[IngredientOut]
    steps: list[StepOut]
    creator_notes: list[str]
    dietary_warnings: list[str]

    def ingredient(self, ref: str) -> IngredientOut | None:
        return next((i for i in self.ingredients if i.id == ref), None)


def context_from(version: RecipeVersion, recipe: Recipe) -> VersionContext:
    warnings = version.warning_json or {}
    content = RecipeContent.model_validate(
        {
            "servings": version.servings,
            "ingredients": version.ingredient_json or [],
            "steps": version.step_json or [],
            "creator_notes": warnings.get("creator_notes", []),
            "dietary_warnings": warnings.get("dietary_warnings", []),
        }
    )
    return VersionContext(
        version_id=version.id,
        recipe_id=recipe.id,
        title=version_meta(recipe, version)["title"],
        ingredients=content.ingredients,
        steps=sorted(content.steps, key=lambda s: s.order),
        creator_notes=content.creator_notes,
        dietary_warnings=content.dietary_warnings,
    )


async def version_context(
    session: AsyncSession, user: User, version_id: uuid.UUID
) -> VersionContext:
    """A version the caller may read (``get_accessible_version`` rule), parsed."""
    version, recipe, _saved = await recipes_service.get_accessible_version(
        session, version_id, user=user
    )
    return context_from(version, recipe)


def target_names(name: str, dictionary: IngredientDictionary) -> list[str]:
    """Canonical keys for an ingredient line and each of its alternatives ("spam or bacon")."""
    keys: list[str] = []
    for alt in [name, *alternatives(name)]:
        key = normalize(alt, dictionary).key
        if key and key not in keys:
            keys.append(key)
    return keys


def confidence_label(value: float) -> str:
    return "high" if value >= 0.8 else "medium" if value >= 0.5 else "low"


def _rule_for(names: list[str], rules: dict[str, SeedRule]) -> SeedRule | None:
    return next((rules[n] for n in names if n in rules), None)


async def _advise(
    provider: SubstitutionAdvisor, request: SubstitutionRequest
) -> SubstitutionResponse:
    for attempt in (1, 2):
        try:
            result = await asyncio.wait_for(
                provider.suggest(request), timeout=PROVIDER_TIMEOUT_SECONDS
            )
            return SubstitutionResponse.model_validate(
                result.model_dump(warnings=False)
                if isinstance(result, pydantic.BaseModel)
                else result
            )
        except pydantic.ValidationError as exc:
            if attempt == 2:
                raise ProviderOutputInvalid(
                    "The substitution service returned a malformed answer; try again"
                ) from exc
        except AppError:
            raise
        except Exception as exc:
            log.warning("substitution provider failed", extra={"error_type": type(exc).__name__})
            raise ProviderUnavailable("The substitution service is unavailable") from exc
    raise AssertionError("unreachable")  # pragma: no cover


def _mentions_any(text: str, phrases: list[str], dictionary: IngredientDictionary) -> bool:
    found = scan(text, dictionary)
    keys = set(found.canonical_names) | {
        normalize(m.phrase, dictionary).key for m in found.mentions
    }
    cleaned = f" {found.text} "
    return any(p in keys or f" {clean(p)} " in cleaned for p in phrases if p)


def _allergy_warning(
    candidate: str, has_allergies: bool, dictionary: IngredientDictionary
) -> str | None:
    flags = allergen_flags(candidate, dictionary)
    parts: list[str] = []
    if flags:
        labels = ", ".join(sorted(FLAG_LABELS.get(f, f) for f in flags))
        parts.append(f"Contains common allergens: {labels}.")
    if has_allergies:  # PRD §13.1: label verification for every swap, never "safe for you"
        parts.append(LABEL_CHECK)
    return " ".join(parts) or None


async def _pantry_names(session: AsyncSession, user: User) -> list[str]:
    rows = await session.execute(
        select(PantryItem.normalized_name).where(PantryItem.owner_user_id == user.id)
    )
    return sorted({r for (r,) in rows})


async def suggest(
    session: AsyncSession,
    user: User,
    body: SuggestIn,
    provider: SubstitutionAdvisor,
    now: datetime,
) -> SuggestOut:
    ctx = await version_context(session, user, body.recipe_version_id)
    ingredient = ctx.ingredient(body.ingredient_ref)
    if ingredient is None:
        raise ValidationError(
            "ingredient_ref is not an ingredient of this recipe version",
            extra={"fields": ["ingredient_ref"]},
        )
    dictionary = await load_dictionary(session)
    rules = await load_rules(session)
    prof = await preferences.profile(session, user)
    names = target_names(ingredient.name, dictionary)
    steps = [s for s in ctx.steps if ingredient.id in s.ingredient_refs]

    def out(suggestions: list[SuggestionOut], *, cannot: bool, reason: str | None) -> SuggestOut:
        return SuggestOut(
            recipe_version_id=ctx.version_id,
            ingredient_ref=ingredient.id,
            target_ingredient=ingredient.name,
            suggestions=suggestions,
            cannot_substitute=cannot,
            reason=reason,
            safety_notice=safety_notice,
        )

    safety_notice = None
    target_hits = conflicts(ingredient.name, prof.allergies, dictionary)
    if target_hits:
        safety_notice = (
            f"This recipe uses {ingredient.name}, which matches your allergy list "
            f"({', '.join(target_hits)}). {LABEL_CHECK}"
        )

    blockers = [
        v
        for v in (
            structural_verdict(
                StructuralContext(
                    target_names=frozenset(names),
                    step_texts=tuple(s.instruction for s in steps),
                    recipe_texts=(ctx.title,),
                )
            ),
            creator_warning_verdict(
                [ingredient.name, *names],
                [w for s in steps for w in s.warnings] + ctx.dietary_warnings,
            ),
        )
        if v is not None
    ]
    if blockers:
        return out([], cannot=True, reason=resolve(blockers).reason)

    rule = _rule_for(names, rules)
    if rule is not None and rule.no_swap_reason:
        return out([], cannot=True, reason=rule.no_swap_reason)

    drafts: list[_Draft] = [
        _Draft(source="rule", **s.model_dump()) for s in (rule.suggestions if rule else [])
    ]
    never = [clean(n) for n in (rule.never if rule else [])]
    own_names = [clean(ingredient.name), *names]
    pantry = await _pantry_names(session, user)
    advisor_reason: str | None = None
    if not (rule and rule.exhaustive) and len(drafts) < MAX_SUGGESTIONS:
        request = SubstitutionRequest(
            target_ingredient=ingredient.name,
            recipe_title=ctx.title,
            recipe_step_context=[s.instruction for s in steps],
            recipe_warnings=[w for s in steps for w in s.warnings] + ctx.dietary_warnings,
            pantry_items=pantry,
            constraints=SubstitutionConstraints(
                allergies=prof.allergy_labels, preferences=prof.avoid_labels
            ),
        )
        try:
            advice = await _advise(provider, request)
        except AppError:
            if not drafts:
                raise
            advice = None  # vetted rules still answer; the advisor is a bonus
        if advice is not None:
            advisor_reason = advice.reason if advice.cannot_substitute else None
            for s in advice.suggestions:
                if s.kind == "not_recommended":
                    advisor_reason = advisor_reason or s.rationale
                    continue
                if _mentions_any(s.candidate, never, dictionary):
                    continue
                if _mentions_any(s.candidate, own_names, dictionary):
                    continue  # "use mirin instead of mirin" or the line's own alternative
                drafts.append(
                    _Draft(
                        source="ai",
                        candidate=s.candidate,
                        kind=s.kind,
                        ratio_or_amount=s.ratio_or_amount,
                        rationale=s.rationale,
                        impact_flavor=s.impact_flavor,
                        impact_texture=s.impact_texture,
                        confidence=confidence_label(s.confidence),
                        risks=list(s.risks),
                    )
                )

    kept: list[_Draft] = []
    dropped: list[RuleVerdict] = []
    for d in drafts:
        text = f"{d.candidate} {d.ratio_or_amount}"
        verdicts = [
            v
            for v in (
                allergy_verdict(text, prof.allergies, dictionary, source=d.source),
                avoid_verdict(text, prof.avoid, dictionary, source=d.source),
            )
            if v is not None
        ]
        verdict = resolve(
            [RuleVerdict(Precedence.CULINARY_CREATIVITY, True, "ok", d.source), *verdicts]
        )
        if verdict.allow:
            kept.append(d)
        else:
            dropped.append(verdict)

    in_pantry = set(pantry)
    kept.sort(
        key=lambda d: (
            d.source != "rule",
            not (scan(d.candidate, dictionary).canonical_names & in_pantry),
            _CONF_ORDER.get(d.confidence, 3),
        )
    )
    kept = kept[:MAX_SUGGESTIONS]

    await session.execute(
        delete(SubstitutionSuggestionRecord).where(
            SubstitutionSuggestionRecord.owner_user_id == user.id,
            SubstitutionSuggestionRecord.expires_at <= now,
        )
    )
    served: list[SuggestionOut] = []
    for d in kept:
        overlay = compose_overlay(
            ctx.steps,
            ctx.ingredients,
            [AdaptationSpec("preview", ingredient.id, ingredient.name, d.candidate)],
            dictionary,
        )
        risks = list(dict.fromkeys([*d.risks, *candidate_safety_risks(d.candidate)]))
        if d.kind != "close_equivalent" and NOT_EXACT not in risks:
            risks.append(NOT_EXACT)
        suggestion = SuggestionOut(
            suggestion_id=uuid.uuid4(),
            source=d.source,  # type: ignore[arg-type]
            candidate=d.candidate,
            kind=d.kind,  # type: ignore[arg-type]
            ratio_or_amount=d.ratio_or_amount,
            rationale=d.rationale,
            impact_flavor=d.impact_flavor,
            impact_texture=d.impact_texture,
            adjusted_steps=[
                AdjustedStep(step_id=sid, instruction=str(v["instruction"]))
                for sid, v in overlay.items()
            ],
            confidence=d.confidence,  # type: ignore[arg-type]
            risks=risks,
            allergy_warning=_allergy_warning(d.candidate, bool(prof.allergies), dictionary),
        )
        session.add(
            SubstitutionSuggestionRecord(
                id=suggestion.suggestion_id,
                owner_user_id=user.id,
                recipe_version_id=ctx.version_id,
                ingredient_ref=ingredient.id,
                payload_json=suggestion.model_dump(mode="json") | {"original": ingredient.name},
                expires_at=now + SUGGESTION_TTL,
            )
        )
        served.append(suggestion)
    await session.flush()

    allergy_dropped = any(v.precedence == Precedence.USER_ALLERGY for v in dropped)
    avoid_dropped = any(v.precedence == Precedence.PREFERENCE for v in dropped)
    if not served:
        if allergy_dropped:
            reason = (
                f"Every swap we know for {ingredient.name} contains something on your allergy "
                "list. Keep the original only if it is right for you, or choose another recipe; "
                "check labels and trusted clinical guidance."
            )
        elif avoid_dropped:
            reason = (
                f"The swaps we know for {ingredient.name} use foods you prefer to avoid "
                "(a preference, not an allergy)."
            )
        else:
            reason = (
                f"No suitable substitute for {ingredient.name}. Keep it on your shopping list "
                "or try another recipe."
            )
            if advisor_reason:
                reason = f"{reason} ({advisor_reason})"
        return out([], cannot=True, reason=reason)
    note = None
    if allergy_dropped:
        note = "Some swaps were left out because they contain something on your allergy list."
    elif avoid_dropped:
        note = "Some swaps were left out because they use foods you prefer to avoid."
    return out(served, cannot=False, reason=note)
