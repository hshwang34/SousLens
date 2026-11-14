"""For You and Following feeds (brief 015, DECISIONS #22 and #27).

For You is a deterministic score, no ML:

    score = coverage + 0.3·cuisine_match + 0.2·followed_creator - 0.5·diet_mismatch

Recipes that touch a stated allergy sort after every other recipe and carry the allergen in
``feed.allergy_conflict``. They are never hidden silently and nothing here calls a recipe safe.
Diets are a soft signal read from recipe tags ("vegetarian", "vegetarian-option"); a recipe
without the tag counts as a mismatch, so it ranks lower but stays visible.

The whole published set is scored per request (tens of recipes). Cap or cache this before the
catalogue grows.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import UTC, datetime

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import ValidationError
from app.db.models import Recipe, User, UserPreference
from app.domains.feed.schemas import FeedCard, FeedInfo, FeedPage
from app.domains.matching.dictionary import IngredientDictionary, load_dictionary
from app.domains.matching.fit import FitResult, PantryEntry, fit
from app.domains.matching.service import ingredients_of, load_pantry
from app.domains.recipes import service as recipes_service
from app.domains.safety.content import Sensitivity, conflicts
from app.domains.social.service import followed_ids
from app.domains.users.preferences import profile_for

CUISINE_WEIGHT = 0.3
FOLLOWED_WEIGHT = 0.2
DIET_PENALTY = 0.5
MAX_LIMIT = 50

# A stricter diet satisfies the looser one.
_DIET_SATISFIED_BY = {
    "vegetarian": {"vegetarian", "vegan"},
    "pescatarian": {"pescatarian", "vegetarian", "vegan"},
}


def decode_cursor(cursor: str | None) -> int:
    if not cursor:
        return 0
    if not cursor.startswith("o") or not cursor[1:].isdigit() or len(cursor) > 8:
        raise ValidationError("Invalid cursor")
    return int(cursor[1:])


def _window[T](items: list[T], offset: int, limit: int) -> tuple[list[T], str | None]:
    """One page of an in-memory ranking and the cursor for the next one."""
    limit = max(1, min(limit, MAX_LIMIT))
    more = offset + limit < len(items)
    return items[offset : offset + limit], f"o{offset + limit}" if more else None


def diet_mismatch(diets: list[str], tags: list[str]) -> bool:
    tagged = {t.removesuffix("-option") for t in tags}
    return any(not (_DIET_SATISFIED_BY.get(d, {d}) & tagged) for d in diets)


def allergy_hit(
    recipe: Recipe, allergies: list[Sensitivity], dictionary: IngredientDictionary | None
) -> str | None:
    version = recipe.latest_version
    if not allergies or dictionary is None or version is None:
        return None
    for ingredient in ingredients_of(version):
        hits = conflicts(ingredient.name, allergies, dictionary)
        if hits:
            return hits[0]
    return None


def have_counts(result: FitResult) -> tuple[int, int]:
    """Required lines found in the pantry (available *or* uncertain) and the required total.

    Ranking uses presence, not amounts: a scanned pantry rarely records quantities, so strict
    ``available`` would rank nearly everything at zero. ``can_make`` stays the strict verdict.
    """
    required = [i for i in result.items if not i.optional]
    have = sum(i.status in ("available", "uncertain") for i in required)
    return have, len(required)


@dataclass(frozen=True, slots=True)
class Scored:
    recipe: Recipe
    score: float
    info: FeedInfo


def score_recipe(
    recipe: Recipe,
    *,
    result: FitResult | None,
    cuisines: set[str],
    diets: list[str],
    followed: bool,
    allergy: str | None,
) -> Scored:
    coverage = None
    if result is not None:
        have, total = have_counts(result)
        coverage = 1.0 if total == 0 else have / total
    cuisine = next((t for t in recipe.tags if t in cuisines), None)
    score = (
        (coverage or 0.0)
        + CUISINE_WEIGHT * (cuisine is not None)
        + FOLLOWED_WEIGHT * followed
        - DIET_PENALTY * diet_mismatch(diets, recipe.tags)
    )
    if result is not None:
        reason = "You have {} of {}".format(*have_counts(result))
    elif cuisine is not None:
        reason = cuisine.capitalize()
    elif followed:
        reason = f"From {recipe.owner.display_name}"
    else:
        reason = "New"
    info = FeedInfo(
        reason=reason,
        coverage=coverage,
        can_make=bool(result and result.can_make),
        allergy_conflict=allergy,
    )
    return Scored(recipe=recipe, score=score, info=info)


def rank(scored: list[Scored]) -> list[Scored]:
    def key(s: Scored) -> tuple[bool, float, float, str]:
        published = s.recipe.published_at or datetime.min.replace(tzinfo=UTC)
        return (
            s.info.allergy_conflict is not None,
            -s.score,
            -published.timestamp(),
            str(s.recipe.id),
        )

    return sorted(scored, key=key)


async def _cards(session: AsyncSession, user: User, scored: list[Scored]) -> list[FeedCard]:
    cards = await recipes_service.cards_for(session, [s.recipe for s in scored], user)
    return [
        FeedCard(**card.model_dump(), feed=s.info) for card, s in zip(cards, scored, strict=True)
    ]


async def for_you(
    session: AsyncSession, user: User, *, cursor: str | None, limit: int, now: datetime
) -> FeedPage:
    offset = decode_cursor(cursor)
    recipes = await recipes_service.public_recipes(session)
    prefs = await session.get(UserPreference, user.id)
    profile = await profile_for(session, user.id)
    pantry: list[PantryEntry] = await load_pantry(session, user)
    needs_dictionary = bool(pantry or profile.allergies)
    dictionary = await load_dictionary(session) if needs_dictionary else None
    followed = await followed_ids(session, user)
    cuisines = set(prefs.cuisines) if prefs else set()
    diets = list(prefs.diets) if prefs else []

    scored = []
    for recipe in recipes:
        version = recipe.latest_version
        result = None
        if pantry and dictionary is not None and version is not None:
            result = fit(version.id, ingredients_of(version), pantry, dictionary, now)
        scored.append(
            score_recipe(
                recipe,
                result=result,
                cuisines=cuisines,
                diets=diets,
                followed=recipe.owner_user_id in followed,
                allergy=allergy_hit(recipe, profile.allergies, dictionary),
            )
        )
    page, next_cursor = _window(rank(scored), offset, limit)
    return FeedPage(items=await _cards(session, user, page), next_cursor=next_cursor)


async def following(
    session: AsyncSession, user: User, *, cursor: str | None, limit: int
) -> FeedPage:
    """Followed creators' public recipes, newest first. Following nobody → empty."""
    offset = decode_cursor(cursor)
    ids: set[uuid.UUID] = await followed_ids(session, user)
    if not ids:
        return FeedPage(items=[], next_cursor=None)
    page, next_cursor = _window(await recipes_service.public_recipes(session, ids), offset, limit)
    cards = await recipes_service.cards_for(session, page, user)
    return FeedPage(items=[FeedCard(**c.model_dump()) for c in cards], next_cursor=next_cursor)
