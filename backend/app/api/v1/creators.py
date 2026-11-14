"""Creators and follows (brief 015, DECISIONS #27)."""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Query

from app.core.errors import NotFound, ValidationError
from app.core.security import CurrentUser, OptionalUser
from app.db.engine import DbSession
from app.domains.social import service
from app.domains.social.schemas import CreatorList, CreatorProfile, CreatorSummary

router = APIRouter(tags=["creators"])


def _creator_id(value: str) -> uuid.UUID:
    try:
        return uuid.UUID(value)
    except ValueError as exc:
        raise NotFound("Creator not found") from exc


def _cuisines(raw: str | None) -> list[str]:
    if not raw:
        return []
    values = [c.strip().lower() for c in raw.split(",") if c.strip()]
    unknown = [c for c in values if c not in service.CUISINES]
    if unknown:
        raise ValidationError(
            f"Unknown cuisine(s): {', '.join(unknown[:5])}", extra={"fields": ["cuisines"]}
        )
    return list(dict.fromkeys(values))


@router.get("/creators/suggested", response_model=CreatorList)
async def suggested_creators(
    session: DbSession,
    user: CurrentUser,
    cuisines: Annotated[str | None, Query(max_length=200)] = None,
    limit: Annotated[int, Query(ge=1, le=service.SUGGESTED_MAX)] = 8,
) -> CreatorList:
    return CreatorList(items=await service.suggested(session, user, _cuisines(cuisines), limit))


@router.get("/creators/{creator_id}", response_model=CreatorProfile)
async def creator_profile(
    creator_id: str, session: DbSession, user: OptionalUser
) -> CreatorProfile:
    return await service.profile(session, user, _creator_id(creator_id))


@router.put("/creators/{creator_id}/follow", response_model=CreatorSummary)
async def follow_creator(creator_id: str, session: DbSession, user: CurrentUser) -> CreatorSummary:
    return await service.follow(session, user, _creator_id(creator_id))


@router.delete("/creators/{creator_id}/follow", response_model=CreatorSummary)
async def unfollow_creator(
    creator_id: str, session: DbSession, user: CurrentUser
) -> CreatorSummary:
    return await service.unfollow(session, user, _creator_id(creator_id))


@router.get("/me/following", response_model=CreatorList)
async def my_following(session: DbSession, user: CurrentUser) -> CreatorList:
    return CreatorList(items=await service.following(session, user))
