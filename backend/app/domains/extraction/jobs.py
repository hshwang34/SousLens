"""Extraction and trim jobs: creating them, the limits in front of them, and their status
(brief 008, CAP-02, DECISIONS #19).

* Marking an upload done creates the draft (``extracting``) and one ``extract`` job; doing it
  again returns the same job.
* Limits are checked when the upload is requested *and* when the job is created: video
  extraction off at the monthly soft cap, and at most N extractions per user per UTC month
  (jobs that ended before any AI spend don't count). The count runs under a per-user advisory
  lock so two concurrent requests can't both take the last slot.
* The DB keeps PRD statuses (queued / working / review / failed); the API says
  queued / processing / ready / failed.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.budget import CostGuard, month_start
from app.ai.providers.gemini import GeminiProvider
from app.core.config import Settings
from app.core.errors import (
    NotFound,
    StateConflict,
    ValidationError,
    VideoExtractionDisabled,
    VideoExtractionLimit,
)
from app.db.models import (
    DraftStatus,
    ExtractionJob,
    ExtractionStatus,
    MediaKind,
    RecipeDraft,
    RecipeMedia,
    User,
)
from app.domains.media import service as media
from app.domains.ownership import get_owned_or_404
from app.domains.recipes import drafts
from app.domains.recipes.draft_schemas import DraftContent, DraftExtraction, Title
from app.media.storage import ObjectStorage, clip_key

JobStatusOut = Literal["queued", "processing", "ready", "failed"]
STATUS_OUT: dict[ExtractionStatus, JobStatusOut] = {
    ExtractionStatus.QUEUED: "queued",
    ExtractionStatus.WORKING: "processing",
    ExtractionStatus.REVIEW: "ready",
    ExtractionStatus.FAILED: "failed",
}
MIN_TRIM_MS = 500
MAX_TRIM_MS = 10 * 60 * 1000


class UploadedIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title_hint: Title | None = None


class TrimIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    start_ms: int = Field(ge=0)
    end_ms: int = Field(ge=0)


class JobError(BaseModel):
    code: str
    message: str


class JobOut(BaseModel):
    id: uuid.UUID
    kind: Literal["extract", "trim"]
    status: JobStatusOut
    stage: str | None
    progress: int = Field(ge=0, le=100)
    draft_id: uuid.UUID | None  # null once the draft was deleted (the job is kept)
    media_id: uuid.UUID | None
    clip_id: uuid.UUID | None
    demo: bool
    partial: bool
    clips_ready: int
    clips_failed: int
    error: JobError | None
    attempts: int
    created_at: datetime
    updated_at: datetime
    finished_at: datetime | None


def to_job_out(job: ExtractionJob) -> JobOut:
    result: dict[str, Any] = job.result_json or {}
    params: dict[str, Any] = job.params_json or {}
    extraction = result.get("extraction") or {}
    info = extraction.get("extraction") or {}
    error = None
    if job.status == ExtractionStatus.FAILED:
        error = JobError(
            code=job.error_code or "EXTRACTION_FAILED",
            message=job.error_message or "Something went wrong; the draft is still editable.",
        )
    return JobOut(
        id=job.id,
        kind=job.kind,  # type: ignore[arg-type]
        status=STATUS_OUT[job.status],
        stage=job.stage,
        progress=max(0, min(job.progress or 0, 100)),
        draft_id=job.draft_id,
        media_id=job.original_media_id,
        clip_id=uuid.UUID(params["clip_id"]) if params.get("clip_id") else None,
        demo=bool(result.get("demo", False)),
        partial=bool(info.get("partial", False)),
        clips_ready=len(result.get("clips") or {}),
        clips_failed=len(result.get("clip_failures") or []),
        error=error,
        attempts=job.attempts,
        created_at=job.created_at,
        updated_at=job.updated_at,
        finished_at=job.finished_at,
    )


def job_id_or_404(value: str) -> uuid.UUID:
    try:
        return uuid.UUID(value)
    except ValueError as exc:
        raise NotFound("Job not found") from exc


async def get_job(session: AsyncSession, user: User, job_id: uuid.UUID) -> ExtractionJob:
    return await get_owned_or_404(session, ExtractionJob, job_id, user.id, label="Job")


# --- limits -------------------------------------------------------------------------------


async def _lock_user(session: AsyncSession, user_id: uuid.UUID) -> None:
    await media.lock_user_video(session, user_id)


async def monthly_extractions(
    session: AsyncSession, user_id: uuid.UUID, now: datetime | None = None
) -> int:
    since = month_start(now or datetime.now(UTC))
    stmt = select(func.count(ExtractionJob.id)).where(
        ExtractionJob.owner_user_id == user_id,
        ExtractionJob.kind == "extract",
        ExtractionJob.counts_toward_limit.is_(True),
        ExtractionJob.created_at >= since,
    )
    return int(await session.scalar(stmt) or 0)


async def check_video_allowed(
    session: AsyncSession,
    user: User,
    *,
    settings: Settings,
    provider: object,
    guard: CostGuard,
) -> None:
    """Raises when this user may not start a video extraction right now."""
    if isinstance(provider, GeminiProvider):
        if not provider.configured:
            raise provider.unavailable("video extraction")
        if not await guard.video_extraction_enabled():
            raise VideoExtractionDisabled(
                "Video extraction is paused for the rest of the month. "
                "You can still write the recipe by hand."
            )
    limit = settings.ai_user_video_extractions_per_month
    used = await monthly_extractions(session, user.id)
    if used >= limit:
        raise VideoExtractionLimit(
            f"You've used all {limit} video extractions this month. "
            "You can still write the recipe by hand.",
            extra={"details": {"limit": limit, "used": used}},
        )


# --- start --------------------------------------------------------------------------------


async def start_extraction(
    session: AsyncSession,
    user: User,
    media_id: uuid.UUID,
    body: UploadedIn,
    *,
    settings: Settings,
    storage: ObjectStorage,
    provider: object,
    guard: CostGuard,
) -> tuple[ExtractionJob, bool]:
    """Confirm the upload and create the draft + job. Returns ``(job, created)``."""
    await _lock_user(session, user.id)
    source = await media.confirm_upload(session, user, media_id, storage=storage)
    existing = (
        await session.execute(
            select(ExtractionJob).where(
                ExtractionJob.original_media_id == source.id, ExtractionJob.kind == "extract"
            )
        )
    ).scalar_one_or_none()
    if existing is not None:
        return existing, False
    await check_video_allowed(session, user, settings=settings, provider=provider, guard=guard)

    job_id = uuid.uuid4()
    content = DraftContent(
        title=body.title_hint,
        extraction=DraftExtraction(job_id=job_id, source_media_id=source.id),
    )
    draft = RecipeDraft(
        owner_user_id=user.id,
        structured_draft_json=drafts.normalise(content),
        status=DraftStatus.EXTRACTING,
    )
    session.add(draft)
    await session.flush()
    source.draft_id = draft.id
    job = ExtractionJob(
        id=job_id,
        owner_user_id=user.id,
        draft_id=draft.id,
        original_media_id=source.id,
        kind="extract",
        status=ExtractionStatus.QUEUED,
        attempts=0,
        progress=0,
        stage="queued",
        params_json={"title_hint": body.title_hint} if body.title_hint else None,
        counts_toward_limit=True,
    )
    session.add(job)
    await session.flush()
    await session.refresh(job)
    return job, True


# --- trim ---------------------------------------------------------------------------------


async def request_trim(
    session: AsyncSession,
    user: User,
    draft_id: uuid.UUID,
    step_id: str,
    body: TrimIn,
) -> ExtractionJob:
    """Re-render one step's clip from the source video at ``[start_ms, end_ms)``. The step
    points at the new (pending) clip straight away; the old clip, if it was never published,
    is deleted. Published clips are never touched (they belong to their version)."""
    row = (
        await session.execute(
            select(RecipeDraft)
            .where(RecipeDraft.id == draft_id, RecipeDraft.owner_user_id == user.id)
            .with_for_update()
        )
    ).scalar_one_or_none()
    if row is None:
        raise NotFound("Draft not found")
    if row.status == DraftStatus.PUBLISHED:
        raise StateConflict(
            "This draft was published and is read-only; edit the recipe to start a new draft"
        )
    drafts.ensure_not_extracting(row)
    content = drafts.read_content(row)
    index = next((i for i, s in enumerate(content.steps) if s.id == step_id), None)
    if index is None:
        raise NotFound("Step not found")
    source_id = content.extraction.source_media_id if content.extraction else None
    source = await session.get(RecipeMedia, source_id) if source_id else None
    if (
        source is None
        or source.owner_user_id != user.id
        or source.media_kind != MediaKind.SOURCE_VIDEO
        or source.status != "ready"
    ):
        raise StateConflict(
            "The source video for this draft was deleted, so clips can't be trimmed"
        )
    duration = source.duration_ms or 0
    if body.end_ms > duration or body.start_ms >= body.end_ms:
        raise ValidationError(
            "The clip must start before it ends and stay inside the video",
            extra={"fields": ["body.start_ms", "body.end_ms"]},
        )
    if not (MIN_TRIM_MS <= body.end_ms - body.start_ms <= MAX_TRIM_MS):
        raise ValidationError(
            "A clip must be between half a second and ten minutes long",
            extra={"fields": ["body.start_ms", "body.end_ms"]},
        )

    step = content.steps[index]
    old_id = media.clip_uuid(step.source_clip_id)
    if old_id is not None:
        old = await session.get(RecipeMedia, old_id)
        if old is not None and old.owner_user_id == user.id and old.version_id is None:
            await session.delete(old)  # the trigger queues its object

    clip_id = uuid.uuid4()
    session.add(
        RecipeMedia(
            id=clip_id,
            owner_user_id=user.id,
            recipe_id=row.recipe_id,
            draft_id=row.id,
            source_media_id=source.id,
            step_id=step.id,
            media_kind=MediaKind.STEP_CLIP,
            status="pending",
            storage_key=clip_key(user.id, clip_id),
            mime_type="video/mp4",
            start_ms=body.start_ms,
            end_ms=body.end_ms,
            duration_ms=body.end_ms - body.start_ms,
        )
    )
    steps = [s.model_dump() for s in content.steps]
    steps[index].update(
        source_clip_id=str(clip_id), source_start_ms=body.start_ms, source_end_ms=body.end_ms
    )
    updated = DraftContent.model_validate({**content.model_dump(), "steps": steps})
    row.structured_draft_json = drafts.normalise(updated)
    job = ExtractionJob(
        owner_user_id=user.id,
        draft_id=row.id,
        original_media_id=source.id,
        kind="trim",
        status=ExtractionStatus.QUEUED,
        attempts=0,
        progress=0,
        stage="queued",
        params_json={"clip_id": str(clip_id), "step_id": step.id},
        counts_toward_limit=False,
    )
    session.add(job)
    await session.flush()
    await session.refresh(job)
    return job
