"""Public read side: discover feed + canonical detail for the latest published version."""

from __future__ import annotations

import uuid

from sqlalchemy import select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from app.core.errors import NotFound
from app.db.models import Recipe, RecipeVersion, User, Visibility
from app.domains.recipes.pagination import FeedCursor
from app.domains.recipes.schemas import (
    CreatorRef,
    RecipeCard,
    RecipeContent,
    RecipeDetail,
    RecipePage,
)

MAX_PAGE_SIZE = 100


def _public_published():
    return (
        Recipe.visibility == Visibility.PUBLIC,
        Recipe.published_at.is_not(None),
        Recipe.latest_version_id.is_not(None),
    )


def _base_query():
    return (
        select(Recipe)
        .join(RecipeVersion, RecipeVersion.id == Recipe.latest_version_id)
        .join(User, User.id == Recipe.owner_user_id)
        .options(joinedload(Recipe.owner), joinedload(Recipe.latest_version))
        .where(*_public_published())
    )


def to_card(recipe: Recipe) -> RecipeCard:
    version = recipe.latest_version
    assert version is not None and recipe.published_at is not None
    return RecipeCard(
        recipe_id=recipe.id,
        slug=recipe.slug,
        title=recipe.title,
        summary=recipe.summary,
        tags=list(recipe.tags),
        creator=CreatorRef(id=recipe.owner.id, display_name=recipe.owner.display_name),
        servings=version.servings,
        prep_minutes=version.prep_minutes,
        cook_minutes=version.cook_minutes,
        cover_image_url=recipe.cover_image_url,
        published_at=recipe.published_at,
        recipe_version_id=version.id,
        version_number=version.version_number,
    )


def to_detail(recipe: Recipe, version: RecipeVersion) -> RecipeDetail:
    assert recipe.published_at is not None
    warnings = version.warning_json or {}
    content = RecipeContent(
        servings=version.servings,
        prep_minutes=version.prep_minutes,
        cook_minutes=version.cook_minutes,
        ingredients=version.ingredient_json,
        steps=version.step_json,
        creator_notes=warnings.get("creator_notes", []),
        dietary_warnings=warnings.get("dietary_warnings", []),
    )
    return RecipeDetail(
        recipe_id=recipe.id,
        recipe_version_id=version.id,
        version_number=version.version_number,
        slug=recipe.slug,
        title=recipe.title,
        summary=recipe.summary,
        tags=list(recipe.tags),
        creator=CreatorRef(id=recipe.owner.id, display_name=recipe.owner.display_name),
        creator_id=recipe.owner.id,
        servings=content.servings,
        prep_minutes=content.prep_minutes,
        cook_minutes=content.cook_minutes,
        cover_image_url=recipe.cover_image_url,
        ingredients=content.ingredients,
        steps=content.steps,
        creator_notes=content.creator_notes,
        dietary_warnings=content.dietary_warnings,
        published_at=recipe.published_at,
    )


async def list_public(
    session: AsyncSession,
    *,
    query: str | None,
    tag: str | None,
    cursor: str | None,
    limit: int,
) -> RecipePage:
    limit = max(1, min(limit, MAX_PAGE_SIZE))
    stmt = _base_query()
    if query:
        stmt = stmt.where(Recipe.title.ilike(f"%{_escape_like(query.strip())}%", escape="\\"))
    if tag:
        stmt = stmt.where(Recipe.tags.contains([tag.strip()]))
    if cursor:
        key = FeedCursor.decode(cursor)
        stmt = stmt.where(
            tuple_(Recipe.published_at, Recipe.id) < tuple_(key.published_at, key.recipe_id)
        )
    stmt = stmt.order_by(Recipe.published_at.desc(), Recipe.id.desc()).limit(limit + 1)
    rows = list((await session.execute(stmt)).unique().scalars().all())
    has_more = len(rows) > limit
    rows = rows[:limit]
    next_cursor = None
    if has_more and rows:
        last = rows[-1]
        assert last.published_at is not None
        next_cursor = FeedCursor(published_at=last.published_at, recipe_id=last.id).encode()
    return RecipePage(items=[to_card(r) for r in rows], next_cursor=next_cursor)


async def get_public_detail(session: AsyncSession, recipe_id: uuid.UUID) -> RecipeDetail:
    stmt = _base_query().where(Recipe.id == recipe_id)
    recipe = (await session.execute(stmt)).unique().scalar_one_or_none()
    if recipe is None or recipe.latest_version is None:
        raise NotFound("Recipe not found")
    return to_detail(recipe, recipe.latest_version)


def _escape_like(value: str) -> str:
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
