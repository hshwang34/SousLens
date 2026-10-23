"""Public read side (discover feed, canonical detail, exact versions) and saves (REC-01/02/05).

Visibility rule used everywhere here: a recipe is *visible* to a caller when it is public and
published, or when the caller owns it. Anything else is a 404 (never a 403 with metadata).
"""

from __future__ import annotations

import uuid
from collections.abc import Iterable

from sqlalchemy import delete, or_, select, tuple_
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from app.core.errors import NotFound
from app.db.models import Recipe, RecipeDraft, RecipeVersion, Save, User, Visibility
from app.domains.recipes import drafts
from app.domains.recipes.pagination import FeedCursor
from app.domains.recipes.schemas import (
    CreatorRef,
    MyRecipe,
    RecipeCard,
    RecipeContent,
    RecipeDetail,
    RecipePage,
    SaveStatus,
)
from app.domains.recipes.versions import version_meta

MAX_PAGE_SIZE = 100


def _public_published():
    return (
        Recipe.visibility == Visibility.PUBLIC,
        Recipe.published_at.is_not(None),
        Recipe.latest_version_id.is_not(None),
    )


def _visible_to(user: User | None):
    """Public+published, or owned by ``user`` (any visibility) once it has a version."""
    public = (
        (Recipe.visibility == Visibility.PUBLIC)
        & Recipe.published_at.is_not(None)
        & Recipe.latest_version_id.is_not(None)
    )
    if user is None:
        return public
    owned = (Recipe.owner_user_id == user.id) & Recipe.latest_version_id.is_not(None)
    return or_(public, owned)


def _base_query():
    return (
        select(Recipe)
        .join(RecipeVersion, RecipeVersion.id == Recipe.latest_version_id)
        .join(User, User.id == Recipe.owner_user_id)
        .options(joinedload(Recipe.owner), joinedload(Recipe.latest_version))
    )


def to_card(recipe: Recipe, *, saved: bool | None) -> RecipeCard:
    version = recipe.latest_version
    assert version is not None and recipe.published_at is not None
    return RecipeCard(
        recipe_id=recipe.id,
        slug=recipe.slug,
        **version_meta(recipe, version),
        creator=CreatorRef(id=recipe.owner.id, display_name=recipe.owner.display_name),
        servings=version.servings,
        prep_minutes=version.prep_minutes,
        cook_minutes=version.cook_minutes,
        published_at=recipe.published_at,
        recipe_version_id=version.id,
        version_number=version.version_number,
        saved=saved,
    )


def to_detail(
    recipe: Recipe, version: RecipeVersion, *, saved: bool | None, share_url_base: str
) -> RecipeDetail:
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
        **version_meta(recipe, version),
        creator=CreatorRef(id=recipe.owner.id, display_name=recipe.owner.display_name),
        creator_id=recipe.owner.id,
        servings=content.servings,
        prep_minutes=content.prep_minutes,
        cook_minutes=content.cook_minutes,
        ingredients=content.ingredients,
        steps=content.steps,
        creator_notes=content.creator_notes,
        dietary_warnings=content.dietary_warnings,
        published_at=recipe.published_at,
        share_url=drafts.share_url(share_url_base, recipe.id),
        saved=saved,
    )


async def saved_ids(
    session: AsyncSession, user: User | None, recipe_ids: Iterable[uuid.UUID]
) -> set[uuid.UUID] | None:
    """Which of ``recipe_ids`` the user saved; ``None`` for an anonymous caller."""
    if user is None:
        return None
    ids = list(recipe_ids)
    if not ids:
        return set()
    stmt = select(Save.recipe_id).where(Save.user_id == user.id, Save.recipe_id.in_(ids))
    return set((await session.execute(stmt)).scalars().all())


def _saved_flag(saved: set[uuid.UUID] | None, recipe_id: uuid.UUID) -> bool | None:
    return None if saved is None else recipe_id in saved


async def _cards(session: AsyncSession, rows: list[Recipe], user: User | None) -> list[RecipeCard]:
    saved = await saved_ids(session, user, (r.id for r in rows))
    return [to_card(r, saved=_saved_flag(saved, r.id)) for r in rows]


async def list_public(
    session: AsyncSession,
    *,
    query: str | None,
    tag: str | None,
    cursor: str | None,
    limit: int,
    user: User | None = None,
) -> RecipePage:
    limit = max(1, min(limit, MAX_PAGE_SIZE))
    stmt = _base_query().where(*_public_published())
    if query and query.strip():
        pattern = f"%{_escape_like(query.strip())}%"
        # Title OR any ingredient name (REC-02). ``search_text`` is the lowercased
        # title + ingredient names snapshot written at publish time.
        stmt = stmt.where(
            or_(
                Recipe.title.ilike(pattern, escape="\\"),
                RecipeVersion.search_text.ilike(pattern, escape="\\"),
            )
        )
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
    return RecipePage(items=await _cards(session, rows, user), next_cursor=next_cursor)


async def _visible_recipe(session: AsyncSession, recipe_id: uuid.UUID, user: User | None) -> Recipe:
    stmt = _base_query().where(Recipe.id == recipe_id, _visible_to(user))
    recipe = (await session.execute(stmt)).unique().scalar_one_or_none()
    if recipe is None or recipe.latest_version is None:
        raise NotFound("Recipe not found")
    return recipe


async def get_detail(
    session: AsyncSession, recipe_id: uuid.UUID, *, user: User | None, share_url_base: str
) -> RecipeDetail:
    """Latest published version. 404 for an unpublished recipe unless the caller owns it."""
    recipe = await _visible_recipe(session, recipe_id, user)
    assert recipe.latest_version is not None
    saved = await saved_ids(session, user, [recipe.id])
    return to_detail(
        recipe,
        recipe.latest_version,
        saved=_saved_flag(saved, recipe.id),
        share_url_base=share_url_base,
    )


async def get_version_detail(
    session: AsyncSession, version_id: uuid.UUID, *, user: User, share_url_base: str
) -> RecipeDetail:
    """That exact version, even after the recipe was unpublished (REC-05), but only for a
    caller with a *prior reference* to it. Allowed when at least one holds:

    * the recipe is currently public and published (visible to everyone), or
    * the caller owns the recipe, or
    * the caller has a Save on the recipe.

    TODO(Slice 3, brief 005): also allow a caller who owns a cooking session that pins this
    ``recipe_version_id`` (``cooking_sessions.recipe_version_id == version.id``); sessions
    must keep reading their pinned version after an unpublish.

    Anything else is a 404 indistinguishable from an unknown id.
    """
    stmt = (
        select(RecipeVersion, Recipe)
        .join(Recipe, Recipe.id == RecipeVersion.recipe_id)
        .options(joinedload(Recipe.owner), joinedload(Recipe.latest_version))
        .where(RecipeVersion.id == version_id, Recipe.published_at.is_not(None))
    )
    row = (await session.execute(stmt)).unique().first()
    if row is None:
        raise NotFound("Recipe version not found")
    version, recipe = row
    saved = await saved_ids(session, user, [recipe.id]) or set()
    is_saved = recipe.id in saved
    is_public = recipe.visibility == Visibility.PUBLIC and recipe.latest_version_id is not None
    if not (is_public or recipe.owner_user_id == user.id or is_saved):
        raise NotFound("Recipe version not found")
    return to_detail(recipe, version, saved=is_saved, share_url_base=share_url_base)


# --------------------------------------------------------------------------- saves (REC-02)


async def save(session: AsyncSession, user: User, recipe_id: uuid.UUID) -> SaveStatus:
    recipe = await _visible_recipe(session, recipe_id, user)
    existing = await session.execute(
        select(Save.id).where(Save.user_id == user.id, Save.recipe_id == recipe.id)
    )
    if existing.scalar_one_or_none() is None:
        try:
            async with session.begin_nested():
                session.add(Save(user_id=user.id, recipe_id=recipe.id))
                await session.flush()
        except IntegrityError:
            pass  # concurrent duplicate save: already saved, which is the requested state
    return SaveStatus(recipe_id=recipe.id, saved=True)


async def unsave(session: AsyncSession, user: User, recipe_id: uuid.UUID) -> SaveStatus:
    # Deliberately no visibility check: a learner may always drop a save, even after the
    # recipe was unpublished; an unknown id is simply "not saved". A single bulk DELETE (no
    # ORM load-then-delete) so concurrent unsaves are all 200 with no stale-row warning.
    await session.execute(delete(Save).where(Save.user_id == user.id, Save.recipe_id == recipe_id))
    return SaveStatus(recipe_id=recipe_id, saved=False)


async def list_saved(session: AsyncSession, user: User) -> list[RecipeCard]:
    stmt = (
        _base_query()
        .join(Save, Save.recipe_id == Recipe.id)
        .where(Save.user_id == user.id, _visible_to(user))
        .order_by(Save.created_at.desc(), Save.id.desc())
    )
    rows = list((await session.execute(stmt)).unique().scalars().all())
    return [to_card(r, saved=True) for r in rows]


async def list_mine(session: AsyncSession, user: User) -> list[MyRecipe]:
    stmt = (
        _base_query()
        .where(Recipe.owner_user_id == user.id, Recipe.published_at.is_not(None))
        .order_by(Recipe.published_at.desc(), Recipe.id.desc())
    )
    rows = list((await session.execute(stmt)).unique().scalars().all())
    ids = [r.id for r in rows]
    saved = await saved_ids(session, user, ids) or set()
    with_open_draft: set[uuid.UUID] = set()
    if ids:
        open_stmt = select(RecipeDraft.recipe_id).where(
            RecipeDraft.recipe_id.in_(ids), RecipeDraft.status.in_(drafts.OPEN_DRAFT_STATUSES)
        )
        with_open_draft = {rid for rid in (await session.execute(open_stmt)).scalars() if rid}
    return [
        MyRecipe(
            **to_card(recipe, saved=recipe.id in saved).model_dump(),
            visibility=recipe.visibility.value,
            has_open_draft=recipe.id in with_open_draft,
        )
        for recipe in rows
    ]


def _escape_like(value: str) -> str:
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
