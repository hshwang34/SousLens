"""Public recipe discovery + detail (REC-01), exact versions (REC-05), saves (REC-02) and the
owner actions on a published recipe (edit → new draft, unpublish; REC-05/06)."""

from __future__ import annotations

import uuid
from functools import partial
from typing import Annotated

from fastapi import APIRouter, Query, status
from pydantic import AfterValidator

from app.core.errors import NotFound
from app.core.security import CurrentUser, OptionalUser, SettingsDep
from app.db.engine import DbSession
from app.domains.recipes import drafts, service
from app.domains.recipes.draft_schemas import Draft, check_text
from app.domains.recipes.schemas import RecipeDetail, RecipePage, SaveStatus, UnpublishResult

router = APIRouter(prefix="/recipes", tags=["recipes"])

# Same hygiene as draft text: a NUL would otherwise reach Postgres and 500.
SINGLE_LINE = AfterValidator(partial(check_text, multiline=False))
versions_router = APIRouter(prefix="/recipe-versions", tags=["recipes"])


def _uuid_or_404(value: str, label: str) -> uuid.UUID:
    try:
        return uuid.UUID(value)
    except ValueError as exc:
        raise NotFound(f"{label} not found") from exc


@router.get("", response_model=RecipePage)
async def list_recipes(
    session: DbSession,
    user: OptionalUser,
    query: Annotated[str | None, Query(max_length=120), SINGLE_LINE] = None,
    tag: Annotated[str | None, Query(max_length=64), SINGLE_LINE] = None,
    cursor: Annotated[str | None, Query(max_length=512)] = None,
    limit: Annotated[int, Query(ge=1, le=service.MAX_PAGE_SIZE)] = 20,
) -> RecipePage:
    return await service.list_public(
        session, query=query, tag=tag, cursor=cursor, limit=limit, user=user
    )


@router.get("/{recipe_id}", response_model=RecipeDetail)
async def get_recipe(
    recipe_id: str, session: DbSession, user: OptionalUser, settings: SettingsDep
) -> RecipeDetail:
    return await service.get_detail(
        session,
        _uuid_or_404(recipe_id, "Recipe"),
        user=user,
        share_url_base=settings.share_url_base,
    )


@router.post("/{recipe_id}/save", response_model=SaveStatus)
async def save_recipe(recipe_id: str, session: DbSession, user: CurrentUser) -> SaveStatus:
    return await service.save(session, user, _uuid_or_404(recipe_id, "Recipe"))


@router.delete("/{recipe_id}/save", response_model=SaveStatus)
async def unsave_recipe(recipe_id: str, session: DbSession, user: CurrentUser) -> SaveStatus:
    return await service.unsave(session, user, _uuid_or_404(recipe_id, "Recipe"))


@router.post("/{recipe_id}/edit", response_model=Draft, status_code=status.HTTP_201_CREATED)
async def edit_recipe(recipe_id: str, session: DbSession, user: CurrentUser) -> Draft:
    row = await drafts.start_edit(session, user, _uuid_or_404(recipe_id, "Recipe"))
    return drafts.to_draft(row)


@router.post("/{recipe_id}/unpublish", response_model=UnpublishResult)
async def unpublish_recipe(
    recipe_id: str, session: DbSession, user: CurrentUser
) -> UnpublishResult:
    recipe = await drafts.unpublish(session, user, _uuid_or_404(recipe_id, "Recipe"))
    return UnpublishResult(recipe_id=recipe.id)


@versions_router.get("/{version_id}", response_model=RecipeDetail)
async def get_recipe_version(
    version_id: str, session: DbSession, user: CurrentUser, settings: SettingsDep
) -> RecipeDetail:
    return await service.get_version_detail(
        session,
        _uuid_or_404(version_id, "Recipe version"),
        user=user,
        share_url_base=settings.share_url_base,
    )
