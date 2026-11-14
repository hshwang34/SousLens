"""Transcript retention (brief 014): a capture session's transcript lives only until the draft
made from it is published or discarded. Then its events, its replay bodies and the
interviewer's ledger (which holds her answers) are deleted. Audio is never stored at all.

A transcript that is never published is deleted after ``capture_transcript_ttl_days`` (30) of
inactivity by :func:`reap_abandoned`, which the worker runs next to the upload reaper. Deleting
a draft by any path purges too: a trigger on ``recipe_drafts`` (migration 0011)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import CaptureEvent, CaptureRequest, CaptureSession


async def purge_transcript(session: AsyncSession, row: CaptureSession) -> None:
    await session.execute(delete(CaptureEvent).where(CaptureEvent.session_id == row.id))
    await session.execute(delete(CaptureRequest).where(CaptureRequest.session_id == row.id))
    row.state_json = {}
    row.transcript_purged_at = row.transcript_purged_at or datetime.now(UTC)


async def purge_transcript_for_draft(session: AsyncSession, draft_id: uuid.UUID) -> int:
    rows = (
        (
            await session.execute(
                select(CaptureSession).where(CaptureSession.draft_id == draft_id).with_for_update()
            )
        )
        .scalars()
        .all()
    )
    for row in rows:
        await purge_transcript(session, row)
    return len(rows)


REAP_BATCH = 100


async def reap_abandoned(
    session: AsyncSession, *, ttl_days: int, now: datetime | None = None
) -> int:
    """Purge transcripts idle for ``ttl_days`` that were never published. Sessions still
    ``generating`` are skipped; the worker owns them. Returns how many sessions were purged."""
    cutoff = (now or datetime.now(UTC)) - timedelta(days=ttl_days)
    rows = (
        (
            await session.execute(
                select(CaptureSession)
                .where(
                    CaptureSession.transcript_purged_at.is_(None),
                    CaptureSession.status != "generating",
                    CaptureSession.updated_at < cutoff,
                )
                .order_by(CaptureSession.updated_at)
                .limit(REAP_BATCH)
                .with_for_update(skip_locked=True)
            )
        )
        .scalars()
        .all()
    )
    for row in rows:
        await purge_transcript(session, row)
    return len(rows)
