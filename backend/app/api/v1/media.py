"""Creator video upload, signed media reads and deletion (brief 008, CAP-01, DECISIONS #20).

The phone never sees a provider key or storage credentials: it gets one presigned PUT for its
own video, then short-lived presigned GETs for its media and for published step clips.
"""

from __future__ import annotations

from typing import Annotated, Literal

from fastapi import APIRouter, Query, Request, Response, status

from app.core.security import CurrentUser, OptionalUser, SettingsDep
from app.db.engine import DbSession
from app.db.models import MediaKind
from app.domains.extraction import jobs
from app.domains.media import service
from app.media.storage import ObjectStorage

router = APIRouter(prefix="/media", tags=["media"])


def _storage(request: Request) -> ObjectStorage:
    return request.app.state.storage


@router.post(
    "/upload-intents", response_model=service.UploadIntentOut, status_code=status.HTTP_201_CREATED
)
async def create_upload_intent(
    body: service.UploadIntentIn,
    request: Request,
    session: DbSession,
    user: CurrentUser,
    settings: SettingsDep,
) -> service.UploadIntentOut:
    service.check_declared(body, settings)
    # Refuse before a 200 MB upload, not after it.
    await jobs.check_video_allowed(
        session,
        user,
        settings=settings,
        provider=request.app.state.ai_provider,
        guard=request.app.state.cost_guard,
    )
    return await service.create_upload_intent(
        session, user, body, settings=settings, storage=_storage(request)
    )


@router.post("/{media_id}/uploaded", response_model=jobs.JobOut)
async def mark_uploaded(
    media_id: str,
    request: Request,
    response: Response,
    session: DbSession,
    user: CurrentUser,
    settings: SettingsDep,
    body: jobs.UploadedIn | None = None,
) -> jobs.JobOut:
    job, created = await jobs.start_extraction(
        session,
        user,
        service.media_id_or_404(media_id),
        body or jobs.UploadedIn(),
        settings=settings,
        storage=_storage(request),
        provider=request.app.state.ai_provider,
        guard=request.app.state.cost_guard,
    )
    response.status_code = status.HTTP_202_ACCEPTED if created else status.HTTP_200_OK
    return jobs.to_job_out(job)


@router.get("", response_model=service.MediaList)
async def list_media(
    request: Request,
    session: DbSession,
    user: CurrentUser,
    settings: SettingsDep,
    kind: Annotated[Literal["source_video", "step_clip"] | None, Query()] = None,
) -> service.MediaList:
    rows = await service.list_media(session, user, kind=MediaKind(kind) if kind else None)
    return service.MediaList(
        items=[service.to_media_out(r, _storage(request), settings, with_url=False) for r in rows]
    )


@router.get("/{media_id}", response_model=service.MediaOut)
async def get_media(
    media_id: str,
    request: Request,
    session: DbSession,
    user: OptionalUser,
    settings: SettingsDep,
) -> service.MediaOut:
    row = await service.get_readable_media(session, user, service.media_id_or_404(media_id))
    return service.to_media_out(row, _storage(request), settings)


@router.delete("/{media_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_media(media_id: str, session: DbSession, user: CurrentUser) -> Response:
    await service.delete_media(session, user, service.media_id_or_404(media_id))
    return Response(status_code=status.HTTP_204_NO_CONTENT)
