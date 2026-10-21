"""Creator drafts (REC-03/04). Owner only; anyone else's draft is a 404.

Mounted *before* the public ``/recipes/{recipe_id}`` route so ``/recipes/drafts`` is never
read as a recipe id.
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Response, status

from app.core.errors import NotFound
from app.core.security import CurrentUser, SettingsDep
from app.db.engine import DbSession
from app.domains.recipes import drafts
from app.domains.recipes.draft_schemas import Draft, DraftList, DraftPatch, PublishResult

router = APIRouter(prefix="/recipes/drafts", tags=["drafts"])


def _draft_id(value: str) -> uuid.UUID:
    try:
        return uuid.UUID(value)
    except ValueError as exc:
        raise NotFound("Draft not found") from exc


@router.post("", response_model=Draft, status_code=status.HTTP_201_CREATED)
async def create_draft(
    session: DbSession, user: CurrentUser, body: DraftPatch | None = None
) -> Draft:
    row = await drafts.create_draft(session, user, body or DraftPatch())
    return drafts.to_draft(row)


@router.get("", response_model=DraftList)
async def list_drafts(session: DbSession, user: CurrentUser) -> DraftList:
    rows = await drafts.list_drafts(session, user)
    return DraftList(items=[drafts.to_summary(r) for r in rows])


@router.get("/{draft_id}", response_model=Draft)
async def get_draft(draft_id: str, session: DbSession, user: CurrentUser) -> Draft:
    return drafts.to_draft(await drafts.get_draft_row(session, user, _draft_id(draft_id)))


@router.patch("/{draft_id}", response_model=Draft)
async def patch_draft(
    draft_id: str, body: DraftPatch, session: DbSession, user: CurrentUser
) -> Draft:
    return drafts.to_draft(await drafts.patch_draft(session, user, _draft_id(draft_id), body))


@router.delete("/{draft_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_draft(draft_id: str, session: DbSession, user: CurrentUser) -> Response:
    await drafts.delete_draft(session, user, _draft_id(draft_id))
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post(
    "/{draft_id}/publish", response_model=PublishResult, status_code=status.HTTP_201_CREATED
)
async def publish_draft(
    draft_id: str, session: DbSession, user: CurrentUser, settings: SettingsDep
) -> PublishResult:
    return await drafts.publish(
        session, user, _draft_id(draft_id), share_url_base=settings.share_url_base
    )
