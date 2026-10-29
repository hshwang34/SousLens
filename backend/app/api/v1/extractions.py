"""Extraction / trim job status for polling (brief 008, CAP-02). Owner only."""

from __future__ import annotations

from fastapi import APIRouter

from app.core.security import CurrentUser
from app.db.engine import DbSession
from app.domains.extraction import jobs

router = APIRouter(prefix="/extractions", tags=["extractions"])


@router.get("/{job_id}", response_model=jobs.JobOut)
async def get_job(job_id: str, session: DbSession, user: CurrentUser) -> jobs.JobOut:
    return jobs.to_job_out(await jobs.get_job(session, user, jobs.job_id_or_404(job_id)))
