"""The creator-video worker (brief 008): ``python -m app.workers.extraction``.

A separate process from the API. Each loop it drains the storage-delete outbox, then claims one
job from Postgres with ``SELECT ... FOR UPDATE SKIP LOCKED`` (so several workers never take the
same job) and holds it with a lease it keeps extending. A worker that dies leaves its lease to
expire, and the next claim resumes the job.

Resumable and idempotent:

* The extraction result is checkpointed into ``result_json`` before any clip is rendered, so a
  resumed job never pays for the same Gemini call twice.
* Clip ids are ``uuid5(job_id, step_id)`` and clip rows are inserted ``ON CONFLICT DO
  NOTHING``; finished clips are checkpointed one by one and skipped on resume.
* The Gemini Files API name is checkpointed right after upload; a successor deletes a file a
  crashed attempt never cleaned up.
* Every checkpoint is ``UPDATE ... WHERE worker_id = me AND status = 'working'``: a worker that
  lost its job (lease taken over, or the draft deleted) stops instead of writing over it.

Failure always ends in an editable draft or a clear failed state: a bad video, a budget
refusal, a safety block or malformed AI output fail the job with a code and message and put the
draft back to ``editing``; a transient error (network, 5xx, ffmpeg crash) is retried up to
``WORKER_MAX_ATTEMPTS`` times, then fails the same way. Clip failures never fail the job (CAP-04).
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import shutil
import signal
import socket
import tempfile
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from botocore.exceptions import BotoCoreError, ClientError
from sqlalchemy import and_, or_, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.ai.budget import CostGuard, Denial, UsageMeter
from app.ai.providers.base import ExtractedRecipeDraft, ExtractionRequest
from app.ai.providers.gemini import GeminiProvider
from app.core.config import Settings, get_settings
from app.core.errors import (
    AIBlocked,
    ProviderNotConfigured,
    ProviderOutputInvalid,
    ProviderUnavailable,
)
from app.core.logging import configure_logging
from app.db.models import (
    DraftStatus,
    ExtractionJob,
    ExtractionStatus,
    MediaDeletion,
    MediaKind,
    RecipeDraft,
    RecipeMedia,
)
from app.domains.extraction.pipeline import build_content
from app.domains.media.service import reap_expired_uploads
from app.domains.recipes import drafts
from app.domains.recipes.draft_schemas import DraftContent, DraftExtraction
from app.media import ffmpeg
from app.media.storage import ObjectStorage, clip_key

log = logging.getLogger("souslens.worker")

STORAGE_ERRORS = (BotoCoreError, ClientError)
TRANSIENT = (ProviderUnavailable, ffmpeg.MediaToolError, OSError, *STORAGE_ERRORS)
DELETE_BATCH = 50
MAX_DELETE_ATTEMPTS = 10

MSG = {
    "VIDEO_EXTRACTION_DISABLED": (
        "Video extraction is paused for the rest of the month. Write the recipe by hand below."
    ),
    "AI_SAFETY_BLOCKED": "The AI couldn't read this video. Write the recipe by hand below.",
    "AI_OUTPUT_INVALID": "The AI's answer couldn't be read. Write the recipe by hand below.",
    "PROVIDER_NOT_CONFIGURED": "AI video extraction isn't set up. Write the recipe by hand below.",
    "SOURCE_DELETED": "The video was deleted before it could be processed.",
    "JOB_FAILED": "Processing kept failing. The draft is editable; try uploading again later.",
    "CLIP_SUPERSEDED": "A newer trim replaced this clip.",
    "DRAFT_DELETED": "The draft was deleted.",
    "CLIP_RENDER_FAILED": "This clip couldn't be made. Try trimming it again.",
}


class JobLost(Exception):
    """This worker no longer owns the job (lease taken over, or the job/draft was deleted)."""


class BudgetRefused(Exception):
    pass


class JobFailed(Exception):
    def __init__(self, code: str, message: str, *, counts: bool = True) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.counts = counts


@dataclass
class Claimed:
    id: uuid.UUID
    kind: str
    owner_user_id: uuid.UUID
    draft_id: uuid.UUID
    media_id: uuid.UUID | None
    attempts: int
    result: dict[str, Any] = field(default_factory=dict)
    params: dict[str, Any] = field(default_factory=dict)


async def _file_size(path: Path) -> int:
    return (await asyncio.to_thread(path.stat)).st_size


def clip_id_for(job_id: uuid.UUID, step_id: str) -> uuid.UUID:
    return uuid.uuid5(job_id, f"clip:{step_id}")


class ExtractionWorker:
    def __init__(
        self,
        sessionmaker: async_sessionmaker[AsyncSession],
        settings: Settings,
        *,
        storage: ObjectStorage,
        provider: object,
        guard: CostGuard,
        worker_id: str | None = None,
        workdir: Path | None = None,
    ) -> None:
        self._sm = sessionmaker
        self._settings = settings
        self._storage = storage
        self._provider = provider
        self._guard = guard
        self.worker_id = (worker_id or f"{socket.gethostname()}:{uuid.uuid4().hex[:8]}")[:64]
        self._workdir = (
            workdir or settings.worker_workdir or Path(tempfile.mkdtemp(prefix="souslens-worker-"))
        )
        self._lease = timedelta(seconds=settings.worker_lease_seconds)
        self.heartbeat_seconds = max(self._lease.total_seconds() / 3, 1.0)

    # --- loop -----------------------------------------------------------------------------

    async def run_forever(self, stop: asyncio.Event) -> None:
        log.info("worker started", extra={"worker_id": self.worker_id})
        while not stop.is_set():
            try:
                busy = await self.run_once()
            except Exception:
                log.exception("worker loop error")
                busy = False
            if not busy:
                try:
                    await asyncio.wait_for(stop.wait(), timeout=self._settings.worker_poll_seconds)
                except TimeoutError:
                    pass
        log.info("worker stopped", extra={"worker_id": self.worker_id})

    async def run_once(self) -> bool:
        """Reap expired uploads, drain deletions, then claim and process at most one job.
        True if a job was taken."""
        await self.reap_uploads()
        await self.drain_deletions()
        job = await self.claim()
        if job is None:
            return False
        await self.process(job)
        return True

    # --- claim / lease --------------------------------------------------------------------

    async def claim(self) -> Claimed | None:
        while True:
            async with self._sm() as session, session.begin():
                now = datetime.now(UTC)
                row = (
                    await session.execute(
                        select(ExtractionJob)
                        .where(
                            or_(
                                ExtractionJob.status == ExtractionStatus.QUEUED,
                                and_(
                                    ExtractionJob.status == ExtractionStatus.WORKING,
                                    ExtractionJob.lease_expires_at < now,
                                ),
                            )
                        )
                        .order_by(ExtractionJob.created_at, ExtractionJob.id)
                        .limit(1)
                        .with_for_update(skip_locked=True)
                    )
                ).scalar_one_or_none()
                if row is None:
                    return None
                if row.attempts >= self._settings.worker_max_attempts:
                    # Crash-looping (each attempt died without recording a result): stop here.
                    log.warning("job attempts exhausted", extra={"job_id": str(row.id)})
                    await self._fail_row(
                        session,
                        row,
                        "JOB_FAILED",
                        MSG["JOB_FAILED"],
                        counts=row.counts_toward_limit,
                    )
                    continue
                resumed = row.status == ExtractionStatus.WORKING
                row.status = ExtractionStatus.WORKING
                row.attempts += 1
                row.worker_id = self.worker_id
                row.lease_expires_at = now + self._lease
                await session.flush()
                log.info(
                    "job claimed",
                    extra={
                        "job_id": str(row.id),
                        "kind": row.kind,
                        "attempt": row.attempts,
                        "resumed": resumed,
                    },
                )
                return Claimed(
                    id=row.id,
                    kind=row.kind,
                    owner_user_id=row.owner_user_id,
                    draft_id=row.draft_id,
                    media_id=row.original_media_id,
                    attempts=row.attempts,
                    result=dict(row.result_json or {}),
                    params=dict(row.params_json or {}),
                )

    def _owned(self, job: Claimed) -> Any:
        return and_(
            ExtractionJob.id == job.id,
            ExtractionJob.worker_id == self.worker_id,
            ExtractionJob.status == ExtractionStatus.WORKING,
        )

    async def _checkpoint(
        self,
        job: Claimed,
        session: AsyncSession | None = None,
        *,
        progress: int | None = None,
        stage: str | None = None,
        save_result: bool = False,
    ) -> None:
        values: dict[str, Any] = {"lease_expires_at": datetime.now(UTC) + self._lease}
        if progress is not None:
            values["progress"] = progress
        if stage is not None:
            values["stage"] = stage
        if save_result:
            values["result_json"] = job.result
        stmt = update(ExtractionJob).where(self._owned(job)).values(**values)
        if session is not None:
            res = await session.execute(stmt)
        else:
            async with self._sm() as s, s.begin():
                res = await s.execute(stmt)
        if res.rowcount == 0:  # type: ignore[attr-defined]
            raise JobLost

    async def _heartbeat(self, job: Claimed, work: asyncio.Task[bool], lost: asyncio.Event) -> None:
        """Extend the lease. If the lease is lost, or can't be confirmed (any error), the work
        is cancelled: once another worker may own the job, this one must stop spending."""
        while True:
            await asyncio.sleep(self.heartbeat_seconds)
            try:
                await self._checkpoint(job)
            except JobLost:
                log.warning("lease lost; cancelling work", extra={"job_id": str(job.id)})
            except Exception:
                log.exception("heartbeat failed; cancelling work", extra={"job_id": str(job.id)})
            else:
                continue
            lost.set()
            work.cancel()
            return

    # --- process --------------------------------------------------------------------------

    async def process(self, job: Claimed) -> None:
        jobdir = self._workdir / str(job.id)
        lost = asyncio.Event()
        work = asyncio.create_task(self._work(job, jobdir))
        heartbeat = asyncio.create_task(self._heartbeat(job, work, lost))
        try:
            finished = await work
        except asyncio.CancelledError:
            if not lost.is_set():
                raise  # the worker itself is shutting down
            log.info("job abandoned after lease loss", extra={"job_id": str(job.id)})
            finished = False
        finally:
            heartbeat.cancel()
        if finished:
            shutil.rmtree(jobdir, ignore_errors=True)

    async def _work(self, job: Claimed, jobdir: Path) -> bool:
        """Run the job; map every outcome to failed / retry. True when the job is finished."""
        finished = True
        try:
            if job.kind == "trim":
                await self._trim(job, jobdir)
            else:
                await self._extract(job, jobdir)
        except JobLost:
            log.info("job lost; stopping", extra={"job_id": str(job.id)})
            # Still ours but its draft is gone: end it (no-op if another worker owns it).
            await self._fail(job, "DRAFT_DELETED", MSG["DRAFT_DELETED"], counts=True)
        except ffmpeg.InvalidVideo as exc:
            await self._fail(job, exc.code, exc.message, counts=False, media_status="rejected")
        except JobFailed as exc:
            await self._fail(job, exc.code, exc.message, counts=exc.counts)
        except BudgetRefused:
            code = "VIDEO_EXTRACTION_DISABLED"
            await self._fail(job, code, MSG[code], counts=False)
        except ProviderNotConfigured:
            code = "PROVIDER_NOT_CONFIGURED"
            await self._fail(job, code, MSG[code], counts=False)
        except AIBlocked:
            await self._fail(job, "AI_SAFETY_BLOCKED", MSG["AI_SAFETY_BLOCKED"], counts=True)
        except ProviderOutputInvalid:
            await self._fail(job, "AI_OUTPUT_INVALID", MSG["AI_OUTPUT_INVALID"], counts=True)
        except TRANSIENT as exc:
            finished = await self._retry_or_fail(job, type(exc).__name__)
        except Exception:
            log.exception("job crashed", extra={"job_id": str(job.id)})
            finished = await self._retry_or_fail(job, "Exception")
        return finished

    async def _retry_or_fail(self, job: Claimed, error_type: str) -> bool:
        if job.attempts >= self._settings.worker_max_attempts:
            log.warning("job failed after retries", extra={"job_id": str(job.id)})
            await self._fail(job, "JOB_FAILED", MSG["JOB_FAILED"], counts=True)
            return True
        log.info("job will retry", extra={"job_id": str(job.id), "error_type": error_type})
        async with self._sm() as session, session.begin():
            await session.execute(
                update(ExtractionJob)
                .where(self._owned(job))
                .values(status=ExtractionStatus.QUEUED, worker_id=None, lease_expires_at=None)
            )
        return False

    async def _fail(
        self,
        job: Claimed,
        code: str,
        message: str,
        *,
        counts: bool,
        media_status: str | None = None,
    ) -> None:
        log.info("job failed", extra={"job_id": str(job.id), "error_code": code})
        async with self._sm() as session, session.begin():
            row = (
                await session.execute(
                    select(ExtractionJob).where(self._owned(job)).with_for_update()
                )
            ).scalar_one_or_none()
            if row is None:
                return
            await self._fail_row(session, row, code, message, counts=counts)
            if media_status and row.original_media_id:
                await session.execute(
                    update(RecipeMedia)
                    .where(RecipeMedia.id == row.original_media_id)
                    .values(status=media_status)
                )

    async def _fail_row(
        self, session: AsyncSession, row: ExtractionJob, code: str, message: str, *, counts: bool
    ) -> None:
        row.status = ExtractionStatus.FAILED
        row.error_code = code
        row.error_message = message
        row.counts_toward_limit = counts
        row.lease_expires_at = None
        row.finished_at = datetime.now(UTC)
        if row.kind == "trim":
            clip_id = (row.params_json or {}).get("clip_id")
            if clip_id:
                await session.execute(
                    update(RecipeMedia)
                    .where(RecipeMedia.id == uuid.UUID(clip_id), RecipeMedia.status == "pending")
                    .values(status="failed")
                )
            return
        draft = (
            await session.execute(
                select(RecipeDraft).where(RecipeDraft.id == row.draft_id).with_for_update()
            )
        ).scalar_one_or_none()
        if draft is None or draft.status != DraftStatus.EXTRACTING:
            return
        content = drafts.read_content(draft)
        info = content.extraction or DraftExtraction(
            job_id=row.id, source_media_id=row.original_media_id
        )
        info = info.model_copy(update={"unknowns": [message, *info.unknowns][:20]})
        draft.structured_draft_json = drafts.normalise(
            content.model_copy(update={"extraction": info})
        )
        draft.status = DraftStatus.EDITING

    # --- extract --------------------------------------------------------------------------

    async def _load_source(self, job: Claimed) -> RecipeMedia:
        async with self._sm() as session:
            row = await session.get(RecipeMedia, job.media_id) if job.media_id else None
        if row is None or row.media_kind != MediaKind.SOURCE_VIDEO:
            raise JobFailed("SOURCE_DELETED", MSG["SOURCE_DELETED"], counts=False)
        return row

    async def _download(self, source: RecipeMedia, jobdir: Path) -> Path:
        ext = "mov" if source.mime_type == "video/quicktime" else "mp4"
        path = jobdir / f"source.{ext}"
        await self._storage.download(source.storage_key, path)
        return path

    async def _extract(self, job: Claimed, jobdir: Path) -> None:
        settings = self._settings
        if job.draft_id is None:
            raise JobLost
        await self._checkpoint(job, progress=5, stage="downloading")
        source = await self._load_source(job)
        path = await self._download(source, jobdir)

        await self._checkpoint(job, progress=10, stage="validating")
        probe = await ffmpeg.probe(path, ffprobe=settings.ffprobe_path)
        ffmpeg.validate_probe(probe, max_duration_ms=settings.video_max_duration_ms)
        duration = probe.duration_ms
        async with self._sm() as session, session.begin():
            await self._checkpoint(job, session)
            await session.execute(
                update(RecipeMedia).where(RecipeMedia.id == source.id).values(duration_ms=duration)
            )

        stored = job.result.get("extraction")
        if stored is None:
            await self._checkpoint(job, progress=15, stage="extracting")
            extracted, demo = await self._run_extractor(job, path, source, duration)
            content = build_content(
                extracted,
                duration_ms=duration,
                job_id=job.id,
                source_media_id=source.id,
                demo=demo,
                title_hint=job.params.get("title_hint"),
            )
            job.result["extraction"] = drafts.normalise(content)
            job.result["demo"] = demo
            job.result.pop("gemini_file", None)
            async with self._sm() as session, session.begin():
                await self._checkpoint(
                    job, session, progress=60, stage="rendering_clips", save_result=True
                )
                # The text draft is visible (and safe) before any clip exists.
                await self._write_draft(session, job, content, status=None)
        content = DraftContent.model_validate(job.result["extraction"])

        await self._render_clips(job, jobdir, path, source, content, duration)

        clips: dict[str, str] = job.result.get("clips") or {}
        steps = [s.model_dump() for s in content.steps]
        for step in steps:
            if step["id"] in clips:
                step["source_clip_id"] = clips[step["id"]]
        final = DraftContent.model_validate({**content.model_dump(), "steps": steps})
        async with self._sm() as session, session.begin():
            await self._write_draft(session, job, final, status=DraftStatus.REVIEW)
            res = await session.execute(
                update(ExtractionJob)
                .where(self._owned(job))
                .values(
                    status=ExtractionStatus.REVIEW,
                    progress=100,
                    stage="done",
                    lease_expires_at=None,
                    finished_at=datetime.now(UTC),
                    result_json=job.result,
                )
            )
            if res.rowcount == 0:  # type: ignore[attr-defined]
                raise JobLost
        log.info(
            "extraction ready",
            extra={
                "job_id": str(job.id),
                "steps": len(final.steps),
                "clips": len(clips),
                "clip_failures": len(job.result.get("clip_failures") or []),
            },
        )

    async def _write_draft(
        self,
        session: AsyncSession,
        job: Claimed,
        content: DraftContent,
        *,
        status: DraftStatus | None,
    ) -> None:
        draft = (
            await session.execute(
                select(RecipeDraft).where(RecipeDraft.id == job.draft_id).with_for_update()
            )
        ).scalar_one_or_none()
        if draft is None or draft.status != DraftStatus.EXTRACTING:
            raise JobLost
        draft.structured_draft_json = drafts.normalise(content)
        if status is not None:
            draft.status = status

    async def _save_gemini_file(self, job: Claimed, name: str) -> None:
        job.result["gemini_file"] = name
        await self._checkpoint(job, save_result=True)

    async def _run_extractor(
        self, job: Claimed, path: Path, source: RecipeMedia, duration_ms: int
    ) -> tuple[ExtractedRecipeDraft, bool]:
        request = ExtractionRequest(
            media_ref=str(path),
            mime_type=source.mime_type or "video/mp4",
            duration_ms=duration_ms,
            title_hint=job.params.get("title_hint"),
        )
        provider = self._provider
        if not isinstance(provider, GeminiProvider):
            return await provider.extract(request), True  # type: ignore[attr-defined]
        if not provider.configured:
            raise ProviderNotConfigured
        stale = job.result.get("gemini_file")
        if stale:
            # A previous attempt crashed after uploading; don't leave the copy on Google's side.
            await provider.delete_file(stale)
            job.result.pop("gemini_file", None)
            await self._checkpoint(job, save_result=True)
        plan = provider.plan_video(request)
        await self._checkpoint(job)  # still ours? never reserve for a job someone else holds
        decision = await self._guard.reserve(
            job.owner_user_id, "video", plan.model, plan.ceiling_usd
        )
        if isinstance(decision, Denial):
            raise BudgetRefused(decision.reason)
        meter = UsageMeter(model=plan.model, at=datetime.now(UTC))
        outcome = "cancelled"
        try:
            await self._checkpoint(job)  # and again right before the paid call
            extracted = await provider.extract(
                request, meter, on_file=lambda name: self._save_gemini_file(job, name)
            )
            outcome = "ok"
            return extracted, False
        except AIBlocked:
            outcome = "blocked"
            raise
        except ProviderOutputInvalid:
            outcome = "malformed"
            raise
        except JobLost:
            outcome = "lost"
            raise
        except Exception:
            outcome = "error"
            raise
        finally:
            await asyncio.shield(self._guard.settle(decision, meter, outcome))

    async def _render_clips(
        self,
        job: Claimed,
        jobdir: Path,
        path: Path,
        source: RecipeMedia,
        content: DraftContent,
        duration: int,
    ) -> None:
        spans = [
            (s.id, s.source_start_ms, s.source_end_ms)
            for s in content.steps
            if s.source_start_ms is not None and s.source_end_ms is not None
        ]
        clips: dict[str, str] = job.result.setdefault("clips", {})
        failures: list[str] = job.result.setdefault("clip_failures", [])
        total = max(len(spans), 1)
        for index, (step_id, start, end) in enumerate(spans):
            if step_id in clips or step_id in failures:
                continue
            assert start is not None and end is not None
            clip_id = clip_id_for(job.id, step_id)
            key = clip_key(job.owner_user_id, clip_id)
            out = jobdir / f"{clip_id}.mp4"
            try:
                await ffmpeg.render_clip(
                    path, out, start_ms=start, end_ms=end, ffmpeg=self._settings.ffmpeg_path
                )
                size = await _file_size(out)
                await self._storage.upload(out, key, content_type="video/mp4")
            except (ffmpeg.MediaToolError, OSError, *STORAGE_ERRORS) as exc:
                # CAP-04: a clip failure never blocks the text recipe.
                log.warning(
                    "clip failed",
                    extra={"job_id": str(job.id), "step_id": step_id, "error": type(exc).__name__},
                )
                failures.append(step_id)
                await self._checkpoint(job, save_result=True)
                continue
            clips[step_id] = str(clip_id)
            progress = 60 + int(35 * (index + 1) / total)
            try:
                async with self._sm() as session, session.begin():
                    await self._checkpoint(job, session, progress=progress, save_result=True)
                    await session.execute(
                        pg_insert(RecipeMedia)
                        .values(
                            id=clip_id,
                            owner_user_id=job.owner_user_id,
                            draft_id=job.draft_id,
                            source_media_id=source.id,
                            step_id=step_id,
                            media_kind=MediaKind.STEP_CLIP,
                            status="ready",
                            storage_key=key,
                            mime_type="video/mp4",
                            size_bytes=size,
                            duration_ms=end - start,
                            start_ms=start,
                            end_ms=end,
                            uploaded_at=datetime.now(UTC),
                        )
                        .on_conflict_do_nothing(index_elements=[RecipeMedia.id])
                    )
            except (JobLost, IntegrityError):
                # The draft went away under us: don't leave the uploaded object behind.
                async with self._sm() as session, session.begin():
                    session.add(MediaDeletion(storage_key=key))
                raise JobLost from None
            await asyncio.to_thread(out.unlink, missing_ok=True)

    # --- trim -----------------------------------------------------------------------------

    async def _trim(self, job: Claimed, jobdir: Path) -> None:
        await self._checkpoint(job, progress=10, stage="downloading")
        clip_id = uuid.UUID(job.params["clip_id"])
        async with self._sm() as session:
            clip = await session.get(RecipeMedia, clip_id)
            source = (
                await session.get(RecipeMedia, clip.source_media_id)
                if clip is not None and clip.source_media_id
                else None
            )
        if clip is None:
            raise JobFailed("CLIP_SUPERSEDED", MSG["CLIP_SUPERSEDED"], counts=False)
        if source is None:
            raise JobFailed("SOURCE_DELETED", MSG["SOURCE_DELETED"], counts=False)
        path = await self._download(source, jobdir)
        await self._checkpoint(job, progress=40, stage="rendering_clips")
        out = jobdir / f"{clip.id}.mp4"
        assert clip.start_ms is not None and clip.end_ms is not None
        try:
            await ffmpeg.render_clip(
                path,
                out,
                start_ms=clip.start_ms,
                end_ms=clip.end_ms,
                ffmpeg=self._settings.ffmpeg_path,
            )
        except ffmpeg.MediaToolError as exc:
            if job.attempts < self._settings.worker_max_attempts:
                raise
            raise JobFailed("CLIP_RENDER_FAILED", MSG["CLIP_RENDER_FAILED"], counts=False) from exc
        size = await _file_size(out)
        await self._storage.upload(out, clip.storage_key, content_type="video/mp4")
        async with self._sm() as session, session.begin():
            res = await session.execute(
                update(RecipeMedia)
                .where(RecipeMedia.id == clip.id, RecipeMedia.status == "pending")
                .values(status="ready", size_bytes=size, uploaded_at=datetime.now(UTC))
            )
            if res.rowcount == 0:  # type: ignore[attr-defined]
                # Deleted (a newer trim) while rendering: drop the object we just wrote.
                session.add(MediaDeletion(storage_key=clip.storage_key))
            done = await session.execute(
                update(ExtractionJob)
                .where(self._owned(job))
                .values(
                    status=ExtractionStatus.REVIEW,
                    progress=100,
                    stage="done",
                    lease_expires_at=None,
                    finished_at=datetime.now(UTC),
                )
            )
            if done.rowcount == 0:  # type: ignore[attr-defined]
                raise JobLost

    # --- deletion outbox ------------------------------------------------------------------

    async def reap_uploads(self) -> int:
        async with self._sm() as session, session.begin():
            n = await reap_expired_uploads(session, self._settings)
        if n:
            log.info("reaped expired uploads", extra={"count": n})
        return n

    async def drain_deletions(self) -> int:
        deleted = 0
        async with self._sm() as session, session.begin():
            rows = (
                (
                    await session.execute(
                        select(MediaDeletion)
                        .where(MediaDeletion.attempts < MAX_DELETE_ATTEMPTS)
                        .order_by(MediaDeletion.created_at)
                        .limit(DELETE_BATCH)
                        .with_for_update(skip_locked=True)
                    )
                )
                .scalars()
                .all()
            )
            for row in rows:
                try:
                    await self._storage.delete(row.storage_key)
                except STORAGE_ERRORS:
                    row.attempts += 1
                    log.warning("storage delete failed; will retry")
                    continue
                await session.delete(row)
                deleted += 1
        return deleted


# --- entry point ------------------------------------------------------------------------------


def build_worker(settings: Settings) -> tuple[ExtractionWorker, Any]:
    from app.ai.registry import build_provider
    from app.db.engine import make_engine, make_sessionmaker
    from app.media.storage import build_storage

    engine = make_engine(settings.database_url, echo=settings.db_echo)
    sessionmaker = make_sessionmaker(engine)
    worker = ExtractionWorker(
        sessionmaker,
        settings,
        storage=build_storage(settings),
        provider=build_provider(settings),
        guard=CostGuard(sessionmaker, settings),
    )
    return worker, engine


async def _main(once: bool) -> None:
    settings = get_settings()
    configure_logging(settings.log_level)
    worker, engine = build_worker(settings)
    if settings.environment != "prod":
        await worker._storage.ensure_bucket()  # type: ignore[attr-defined]
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    try:
        if once:
            while await worker.run_once():
                pass
        else:
            await worker.run_forever(stop)
    finally:
        await engine.dispose()


def main() -> None:
    parser = argparse.ArgumentParser(description="SousLens creator-video worker")
    parser.add_argument("--once", action="store_true", help="process queued jobs, then exit")
    args = parser.parse_args()
    asyncio.run(_main(args.once))


if __name__ == "__main__":
    main()
