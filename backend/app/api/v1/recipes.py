"""Public recipe discovery + detail (REC-01). No auth required."""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Query

from app.core.errors import NotFound
from app.db.engine import DbSession
from app.domains.recipes import service
from app.domains.recipes.schemas import RecipeDetail, RecipePage

router = APIRouter(prefix="/recipes", tags=["recipes"])


@router.get("", response_model=RecipePage)
async def list_recipes(
    session: DbSession,
    query: Annotated[str | None, Query(max_length=120)] = None,
    tag: Annotated[str | None, Query(max_length=64)] = None,
    cursor: Annotated[str | None, Query(max_length=512)] = None,
    limit: Annotated[int, Query(ge=1, le=service.MAX_PAGE_SIZE)] = 20,
) -> RecipePage:
    return await service.list_public(session, query=query, tag=tag, cursor=cursor, limit=limit)


@router.get("/{recipe_id}", response_model=RecipeDetail)
async def get_recipe(recipe_id: str, session: DbSession) -> RecipeDetail:
    try:
        parsed = uuid.UUID(recipe_id)
    except ValueError as exc:
        raise NotFound("Recipe not found") from exc
    return await service.get_public_detail(session, parsed)
