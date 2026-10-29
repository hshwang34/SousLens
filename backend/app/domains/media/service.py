"""Creator media: upload intents, upload confirmation, signed reads, deletion (brief 008).

* Every row is owned; another creator's media is the same 404 as a missing one.
* A source video is kept until the creator deletes it (DECISIONS #20). Clips attach to the first
  published version that uses them and are then kept; unpublished clips go with their draft.
* Storage deletes go through the ``media_deletions`` outbox: a database trigger queues the
  object whenever a ``recipe_media`` row is deleted (by any path, cascades included), in the
  same transaction, so a rollback never orphans a row and a commit never forgets an object.
* Abuse caps (fix round 1): at most N pending (unconfirmed) source uploads per user, and a
  monthly byte budget per user counted from a durable ledger (deleting media never refunds it).
  Pending uploads whose URL expired are reaped by the worker.
"""

from __future__ import annotations

import logging
import uuid
from collections.abc import Iterable
from datetime import UTC, datetime, timedelta
from typing import Literal

from botocore.exceptions import BotoCoreError, ClientError
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import delete, func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.budget import month_start
from app.core.config import Settings
from app.core.errors import (
    NotFound,
    RightsConfirmationRequired,
    StateConflict,
    StorageUnavailable,
    UploadIncomplete,
    UploadLimit,
    VideoTooLarge,
    VideoTooLong,
    VideoTypeUnsupported,
)
from app.db.models import (
    ExtractionJob,
    ExtractionStatus,
    MediaConsent,
    MediaDeletion,
    MediaKind,
    Recipe,
    RecipeMedia,
    UsageEvent,
    User,
    Visibility,
)
from app.domains.ownership import get_owned_or_404
from app.media.storage import ObjectStorage, source_key

log = logging.getLogger("souslens.media")

VIDEO_TYPES: dict[str, str] = {"video/mp4": "mp4", "video/quicktime": "mov"}
CONSENT_TYPE = "own_video_rights"
UPLOAD_BYTES_KIND = "video_upload_bytes"
ACTIVE_JOB_STATUSES = (ExtractionStatus.QUEUED, ExtractionStatus.WORKING)


class UploadIntentIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    content_type: str = Field(max_length=100)
    size_bytes: int = Field(ge=1)
    duration_ms: int | None = Field(default=None, ge=0)
    owns_rights: bool = False


class UploadIntentOut(BaseModel):
    media_id: uuid.UUID
    upload_url: str
    method: Literal["PUT"] = "PUT"
    headers: dict[str, str]
    expires_at: datetime
    max_bytes: int
    max_duration_ms: int


class MediaOut(BaseModel):
    id: uuid.UUID
    kind: Literal["source_video", "step_clip", "cover_image"]
    status: Literal["pending", "ready", "failed", "rejected"]
    mime_type: str | None
    size_bytes: int | None
    duration_ms: int | None
    start_ms: int | None
    end_ms: int | None
    draft_id: uuid.UUID | None
    recipe_id: uuid.UUID | None
    step_id: str | None
    published: bool
    url: str | None
    url_expires_at: datetime | None
    created_at: datetime


class MediaList(BaseModel):
    items: list[MediaOut]


def media_id_or_404(value: str) -> uuid.UUID:
    try:
        return uuid.UUID(value)
    except ValueError as exc:
        raise NotFound("Media not found") from exc


def to_media_out(
    row: RecipeMedia, storage: ObjectStorage | None, settings: Settings, *, with_url: bool = True
) -> MediaOut:
    url = expires = None
    if with_url and storage is not None and row.status == "ready":
        ttl = settings.storage_download_url_ttl_seconds
        url = storage.presign_get(row.storage_key, expires_in=ttl, content_type=row.mime_type)
        expires = datetime.now(UTC) + timedelta(seconds=ttl)
    return MediaOut(
        id=row.id,
        kind=row.media_kind.value,  # type: ignore[arg-type]
        status=row.status,  # type: ignore[arg-type]
        mime_type=row.mime_type,
        size_bytes=row.size_bytes,
        duration_ms=row.duration_ms,
        start_ms=row.start_ms,
        end_ms=row.end_ms,
        draft_id=row.draft_id,
        recipe_id=row.recipe_id,
        step_id=row.step_id,
        published=row.version_id is not None,
        url=url,
        url_expires_at=expires,
        created_at=row.created_at,
    )


def check_declared(body: UploadIntentIn, settings: Settings) -> str:
    """CAP-01 checks on what the phone declares; the worker re-checks the real file."""
    if not body.owns_rights:
        raise RightsConfirmationRequired(
            "Confirm that this is your own video and you have the rights to share it."
        )
    content_type = body.content_type.strip().lower()
    ext = VIDEO_TYPES.get(content_type)
    if ext is None:
        raise VideoTypeUnsupported("Only MP4 and MOV videos are supported.")
    if body.size_bytes > settings.video_max_bytes:
        mb = settings.video_max_bytes // (1024 * 1024)
        raise VideoTooLarge(f"Videos can be at most {mb} MB.")
    if body.duration_ms is not None and body.duration_ms > settings.video_max_duration_ms:
        minutes = settings.video_max_duration_ms // 60000
        raise VideoTooLong(f"Videos can be at most {minutes} minutes long.")
    return content_type


async def create_upload_intent(
    session: AsyncSession,
    user: User,
    body: UploadIntentIn,
    *,
    settings: Settings,
    storage: ObjectStorage,
) -> UploadIntentOut:
    content_type = check_declared(body, settings)
    await lock_user_video(session, user.id)
    now = datetime.now(UTC)
    pending = await session.scalar(
        select(func.count(RecipeMedia.id)).where(
            RecipeMedia.owner_user_id == user.id,
            RecipeMedia.media_kind == MediaKind.SOURCE_VIDEO,
            RecipeMedia.status == "pending",
        )
    )
    if int(pending or 0) >= settings.video_max_pending_uploads:
        raise UploadLimit(
            "Finish or cancel your other video upload first.",
            extra={"details": {"pending": int(pending or 0)}},
        )
    used = await session.scalar(
        select(func.coalesce(func.sum(UsageEvent.amount), 0)).where(
            UsageEvent.user_id == user.id,
            UsageEvent.kind == UPLOAD_BYTES_KIND,
            UsageEvent.created_at >= month_start(now),
        )
    )
    if int(used or 0) + body.size_bytes > settings.video_upload_bytes_per_month:
        raise UploadLimit(
            "You've reached this month's video upload allowance.",
            extra={"details": {"limit_bytes": settings.video_upload_bytes_per_month}},
        )
    session.add(
        UsageEvent(user_id=user.id, kind=UPLOAD_BYTES_KIND, amount=body.size_bytes, created_at=now)
    )
    media_id = uuid.uuid4()
    consent = MediaConsent(
        owner_user_id=user.id,
        content_id=media_id,
        consent_type=CONSENT_TYPE,
        captured_at=now,
        confirmed_rights=True,
    )
    session.add(consent)
    await session.flush()
    key = source_key(user.id, media_id, VIDEO_TYPES[content_type])
    row = RecipeMedia(
        id=media_id,
        owner_user_id=user.id,
        media_kind=MediaKind.SOURCE_VIDEO,
        status="pending",
        storage_key=key,
        mime_type=content_type,
        size_bytes=body.size_bytes,
        duration_ms=body.duration_ms,
        consent_record_id=consent.id,
    )
    session.add(row)
    await session.flush()
    ttl = settings.storage_upload_url_ttl_seconds
    url = storage.presign_put(
        key, content_type=content_type, content_length=body.size_bytes, expires_in=ttl
    )
    return UploadIntentOut(
        media_id=media_id,
        upload_url=url,
        headers={"Content-Type": content_type, "Content-Length": str(body.size_bytes)},
        expires_at=now + timedelta(seconds=ttl),
        max_bytes=settings.video_max_bytes,
        max_duration_ms=settings.video_max_duration_ms,
    )


async def get_owned_media(session: AsyncSession, user: User, media_id: uuid.UUID) -> RecipeMedia:
    return await get_owned_or_404(session, RecipeMedia, media_id, user.id, label="Media")


async def confirm_upload(
    session: AsyncSession, user: User, media_id: uuid.UUID, *, storage: ObjectStorage
) -> RecipeMedia:
    """Lock the row and check the object really is in storage with the declared size and type.
    Idempotent: an already-confirmed upload is returned as is."""
    row = (
        await session.execute(
            select(RecipeMedia)
            .where(RecipeMedia.id == media_id, RecipeMedia.owner_user_id == user.id)
            .with_for_update()
        )
    ).scalar_one_or_none()
    if row is None or row.media_kind != MediaKind.SOURCE_VIDEO:
        raise NotFound("Media not found")
    if row.status == "ready":
        return row
    if row.status != "pending":
        raise StateConflict("This video was rejected; upload it again")
    try:
        info = await storage.head(row.storage_key)
    except (BotoCoreError, ClientError) as exc:
        log.warning("storage head failed", extra={"error_type": type(exc).__name__})
        raise StorageUnavailable("Storage is unavailable right now; try again") from exc
    if info is None:
        raise UploadIncomplete("The video hasn't finished uploading yet.")
    if row.size_bytes is not None and info.size_bytes != row.size_bytes:
        raise UploadIncomplete("The uploaded file doesn't match the declared size; upload again.")
    if info.content_type and info.content_type.split(";")[0].strip().lower() != row.mime_type:
        raise UploadIncomplete("The uploaded file doesn't match the declared type; upload again.")
    row.size_bytes = info.size_bytes
    row.status = "ready"
    row.uploaded_at = datetime.now(UTC)
    await session.flush()
    return row


async def lock_user_video(session: AsyncSession, user_id: uuid.UUID) -> None:
    """Serialise one user's video limit checks (transaction-scoped advisory lock)."""
    await session.execute(
        text("SELECT pg_advisory_xact_lock(hashtextextended(:k, 0))"),
        {"k": f"souslens:video:{user_id}"},
    )


async def reap_expired_uploads(
    session: AsyncSession, settings: Settings, now: datetime | None = None
) -> int:
    """Delete pending source rows whose upload URL has expired (plus a minute of grace); the
    trigger queues their objects in case a late PUT landed."""
    now = now or datetime.now(UTC)
    cutoff = now - timedelta(seconds=settings.storage_upload_url_ttl_seconds + 60)
    res = await session.execute(
        delete(RecipeMedia).where(
            RecipeMedia.media_kind == MediaKind.SOURCE_VIDEO,
            RecipeMedia.status == "pending",
            RecipeMedia.created_at < cutoff,
        )
    )
    return int(res.rowcount or 0)  # type: ignore[attr-defined]


def enqueue_deletions(session: AsyncSession, keys: Iterable[str]) -> None:
    """For objects that have no ``recipe_media`` row (rows are queued by the trigger)."""
    for key in keys:
        session.add(MediaDeletion(storage_key=key))


async def delete_media(session: AsyncSession, user: User, media_id: uuid.UUID) -> None:
    row = (
        await session.execute(
            select(RecipeMedia)
            .where(RecipeMedia.id == media_id, RecipeMedia.owner_user_id == user.id)
            .with_for_update()
        )
    ).scalar_one_or_none()
    if row is None:
        raise NotFound("Media not found")
    if row.media_kind == MediaKind.SOURCE_VIDEO:
        active = (
            await session.execute(
                select(ExtractionJob.id)
                .where(
                    ExtractionJob.original_media_id == row.id,
                    ExtractionJob.status.in_(ACTIVE_JOB_STATUSES),
                )
                .limit(1)
            )
        ).scalar_one_or_none()
        if active is not None:
            raise StateConflict(
                "This video is still being processed; delete it when processing ends",
                extra={"details": {"job_id": str(active)}},
            )
    elif row.version_id is not None:
        raise StateConflict("This clip is part of a published recipe version and is kept with it")
    await session.delete(row)
    await session.flush()
    # Audit trail for creator deletions (PRD §13.2); ids only, never content.
    log.info(
        "creator media deleted",
        extra={"media_id": str(media_id), "kind": row.media_kind.value, "user_id": str(user.id)},
    )


async def list_media(
    session: AsyncSession, user: User, *, kind: MediaKind | None = None
) -> list[RecipeMedia]:
    stmt = select(RecipeMedia).where(RecipeMedia.owner_user_id == user.id)
    if kind is not None:
        stmt = stmt.where(RecipeMedia.media_kind == kind)
    stmt = stmt.order_by(RecipeMedia.created_at.desc(), RecipeMedia.id.desc())
    return list((await session.execute(stmt)).scalars().all())


async def get_readable_media(
    session: AsyncSession, user: User | None, media_id: uuid.UUID
) -> RecipeMedia:
    """The owner can read any of their media. Anyone else can read a *step clip* attached to a
    published version of a recipe that is not private (cooks playing clips)."""
    row = await session.get(RecipeMedia, media_id)
    if row is None:
        raise NotFound("Media not found")
    if user is not None and row.owner_user_id == user.id:
        return row
    if row.media_kind != MediaKind.STEP_CLIP or row.version_id is None or row.recipe_id is None:
        raise NotFound("Media not found")
    recipe = await session.get(Recipe, row.recipe_id)
    if recipe is None or recipe.visibility == Visibility.PRIVATE:
        raise NotFound("Media not found")
    return row


# --- Draft lifecycle hooks (called from domains.recipes.drafts) ------------------------------


async def discard_unpublished_clips(
    session: AsyncSession, draft_id: uuid.UUID, *, keep: set[uuid.UUID] | None = None
) -> int:
    """Delete this draft's clips that never reached a published version (except ``keep``)."""
    stmt = select(RecipeMedia).where(
        RecipeMedia.draft_id == draft_id,
        RecipeMedia.media_kind == MediaKind.STEP_CLIP,
        RecipeMedia.version_id.is_(None),
    )
    rows = [r for r in (await session.execute(stmt)).scalars().all() if r.id not in (keep or ())]
    if not rows:
        return 0
    await session.execute(delete(RecipeMedia).where(RecipeMedia.id.in_([r.id for r in rows])))
    return len(rows)


def clip_uuid(value: str | None) -> uuid.UUID | None:
    if not value:
        return None
    try:
        return uuid.UUID(value)
    except ValueError:
        return None


async def owned_clips(
    session: AsyncSession, owner_id: uuid.UUID, clip_ids: Iterable[uuid.UUID]
) -> dict[uuid.UUID, RecipeMedia]:
    ids = list(set(clip_ids))
    if not ids:
        return {}
    stmt = select(RecipeMedia).where(
        RecipeMedia.id.in_(ids),
        RecipeMedia.owner_user_id == owner_id,
        RecipeMedia.media_kind == MediaKind.STEP_CLIP,
    )
    return {r.id: r for r in (await session.execute(stmt)).scalars().all()}


async def attach_on_publish(
    session: AsyncSession,
    *,
    owner_id: uuid.UUID,
    draft_id: uuid.UUID,
    recipe_id: uuid.UUID,
    version_id: uuid.UUID,
    clip_ids: Iterable[uuid.UUID],
    source_media_id: uuid.UUID | None,
) -> None:
    """Clips used by the published steps join the version (first version wins and keeps them);
    the draft's other unpublished clips are discarded. The source video joins the recipe."""
    clips = await owned_clips(session, owner_id, clip_ids)
    for clip in clips.values():
        # A clip already in a published version is immutable: never re-pointed (publish
        # validation only lets this draft's own clips or this recipe's clips through).
        if clip.version_id is None:
            clip.version_id = version_id
            clip.recipe_id = recipe_id
    await discard_unpublished_clips(session, draft_id, keep=set(clips))
    if source_media_id is not None:
        source = await session.get(RecipeMedia, source_media_id)
        if source is not None and source.owner_user_id == owner_id:
            source.recipe_id = recipe_id
    await session.flush()
