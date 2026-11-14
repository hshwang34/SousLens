"""Follow creators, creator profiles and onboarding suggestions (brief 015, DECISIONS #27).

A *creator* is any user with at least one public, published recipe. Nobody can follow
themselves, and a user who is not a creator answers 404 exactly like an unknown id.
"""

from __future__ import annotations

import uuid
from collections import defaultdict
from collections.abc import Iterable
from typing import get_args

from sqlalchemy import delete, func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import NotFound
from app.db.models import Follow, Recipe, User
from app.domains.recipes import service as recipes_service
from app.domains.social.schemas import CreatorProfile, CreatorSummary
from app.domains.users.preferences import Cuisine

CUISINES: tuple[str, ...] = get_args(Cuisine)
SUGGESTED_MAX = 20


def cuisines_of(recipes: Iterable[Recipe]) -> list[str]:
    """Cuisine-vocabulary tags across recipes, most frequent first (ties: vocabulary order)."""
    counts: dict[str, int] = defaultdict(int)
    for recipe in recipes:
        for tag in recipe.tags:
            if tag in CUISINES:
                counts[tag] += 1
    return sorted(counts, key=lambda c: (-counts[c], CUISINES.index(c)))


async def _follower_counts(session: AsyncSession, ids: list[uuid.UUID]) -> dict[uuid.UUID, int]:
    if not ids:
        return {}
    stmt = (
        select(Follow.creator_id, func.count())
        .where(Follow.creator_id.in_(ids))
        .group_by(Follow.creator_id)
    )
    return {row[0]: row[1] for row in (await session.execute(stmt)).all()}


async def followed_ids(session: AsyncSession, user: User | None) -> set[uuid.UUID]:
    if user is None:
        return set()
    stmt = select(Follow.creator_id).where(Follow.follower_id == user.id)
    return set((await session.execute(stmt)).scalars().all())


async def _summaries(
    session: AsyncSession, user: User | None, owner_ids: list[uuid.UUID] | None = None
) -> dict[uuid.UUID, tuple[CreatorSummary, list[Recipe]]]:
    """Creators (optionally only ``owner_ids``) → (summary, their public recipes newest first)."""
    by_owner: dict[uuid.UUID, list[Recipe]] = defaultdict(list)
    owners: dict[uuid.UUID, User] = {}
    for recipe in await recipes_service.public_recipes(session, owner_ids):
        by_owner[recipe.owner_user_id].append(recipe)
        owners[recipe.owner_user_id] = recipe.owner
    ids = list(by_owner)
    followers = await _follower_counts(session, ids)
    following = await followed_ids(session, user)
    out: dict[uuid.UUID, tuple[CreatorSummary, list[Recipe]]] = {}
    for owner_id, recipes in by_owner.items():
        owner = owners[owner_id]
        summary = CreatorSummary(
            id=owner.id,
            display_name=owner.display_name,
            bio=owner.bio,
            avatar_url=owner.avatar_url,
            recipe_count=len(recipes),
            follower_count=followers.get(owner_id, 0),
            is_following=owner_id in following,
            cuisines=cuisines_of(recipes),
            sample_recipe_titles=[r.title for r in recipes[:2]],
        )
        out[owner_id] = (summary, recipes)
    return out


async def _creator_or_404(
    session: AsyncSession, user: User | None, creator_id: uuid.UUID
) -> tuple[CreatorSummary, list[Recipe]]:
    found = (await _summaries(session, user, [creator_id])).get(creator_id)
    if found is None:
        raise NotFound("Creator not found")
    return found


async def suggested(
    session: AsyncSession, user: User, cuisines: list[str], limit: int
) -> list[CreatorSummary]:
    """Onboarding suggestions: cuisine overlap, then recipe count, then name. Excludes self."""
    wanted = set(cuisines)
    summaries = [s for s, _ in (await _summaries(session, user)).values() if s.id != user.id]
    summaries.sort(
        key=lambda s: (-len(wanted & set(s.cuisines)), -s.recipe_count, s.display_name.lower())
    )
    return summaries[: max(1, min(limit, SUGGESTED_MAX))]


async def profile(
    session: AsyncSession, user: User | None, creator_id: uuid.UUID
) -> CreatorProfile:
    summary, recipes = await _creator_or_404(session, user, creator_id)
    return CreatorProfile(
        creator=summary, recipes=await recipes_service.cards_for(session, recipes, user)
    )


async def follow(session: AsyncSession, user: User, creator_id: uuid.UUID) -> CreatorSummary:
    if creator_id == user.id:
        raise NotFound("Creator not found")
    await _creator_or_404(session, user, creator_id)
    stmt = pg_insert(Follow).values(follower_id=user.id, creator_id=creator_id)
    await session.execute(stmt.on_conflict_do_nothing())
    summary, _ = await _creator_or_404(session, user, creator_id)
    return summary


async def unfollow(session: AsyncSession, user: User, creator_id: uuid.UUID) -> CreatorSummary:
    """Idempotent for creators. If the creator has since unpublished everything, the caller can
    still drop a follow they hold and gets a bare summary; with no follow to drop, a non-creator
    answers 404 like an unknown id, so this never reveals anything about arbitrary users."""
    if creator_id == user.id:
        raise NotFound("Creator not found")
    deleted = await session.execute(
        delete(Follow)
        .where(Follow.follower_id == user.id, Follow.creator_id == creator_id)
        .returning(Follow.creator_id)
    )
    existed = deleted.first() is not None
    found = (await _summaries(session, user, [creator_id])).get(creator_id)
    if found is not None:
        return found[0]
    target = await session.get(User, creator_id) if existed else None
    if target is None:
        raise NotFound("Creator not found")
    # The follower already saw this name while the creator was public; bio/avatar are withheld.
    return CreatorSummary(
        id=target.id,
        display_name=target.display_name,
        bio=None,
        avatar_url=None,
        recipe_count=0,
        follower_count=(await _follower_counts(session, [creator_id])).get(creator_id, 0),
        is_following=False,
        cuisines=[],
        sample_recipe_titles=[],
    )


async def following(session: AsyncSession, user: User) -> list[CreatorSummary]:
    """Creators the user follows who still have public recipes, most recent follow first."""
    stmt = (
        select(Follow.creator_id)
        .where(Follow.follower_id == user.id)
        .order_by(Follow.created_at.desc(), Follow.creator_id)
    )
    order = list((await session.execute(stmt)).scalars().all())
    summaries = await _summaries(session, user, order)
    return [summaries[i][0] for i in order if i in summaries]
