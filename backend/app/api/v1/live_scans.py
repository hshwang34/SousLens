"""Live pantry scan basket (brief 016 PR 3). Owner only; nothing is pantry truth until finish."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

from fastapi import APIRouter, Response, status

from app.core.errors import NotFound
from app.core.security import CurrentUser
from app.db.engine import DbSession
from app.domains.matching.dictionary import load_dictionary
from app.domains.pantry import live_scan
from app.domains.pantry.schemas import (
    CreateLiveScan,
    LiveItemIn,
    LiveItemOut,
    LiveScanCreated,
    LiveScanFinished,
    LiveScanOut,
)

router = APIRouter(prefix="/pantry/live-scans", tags=["pantry"])


def _now() -> datetime:
    return datetime.now(UTC)


def _scan_id(value: str) -> uuid.UUID:
    try:
        return uuid.UUID(value)
    except ValueError as exc:
        raise NotFound("Live scan not found") from exc


@router.post("", response_model=LiveScanCreated, status_code=status.HTTP_201_CREATED)
async def create_live_scan(
    session: DbSession, user: CurrentUser, body: CreateLiveScan | None = None
) -> LiveScanCreated:
    scan = await live_scan.create_scan(session, user, bool(body and body.demo), _now())
    return LiveScanCreated(id=scan.id, demo=scan.demo, expires_at=scan.expires_at)


@router.get("/{scan_id}", response_model=LiveScanOut)
async def get_live_scan(scan_id: str, session: DbSession, user: CurrentUser) -> LiveScanOut:
    return await live_scan.get_scan(session, user, _scan_id(scan_id), _now())


@router.post("/{scan_id}/items", response_model=LiveItemOut)
async def add_live_item(
    scan_id: str, body: LiveItemIn, session: DbSession, user: CurrentUser
) -> LiveItemOut:
    dictionary = await load_dictionary(session)
    return await live_scan.add_item(session, user, _scan_id(scan_id), body, dictionary, _now())


@router.delete("/{scan_id}/items/{key}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_live_item(
    scan_id: str, key: str, session: DbSession, user: CurrentUser
) -> Response:
    await live_scan.remove_item(session, user, _scan_id(scan_id), key, _now())
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/{scan_id}/finish", response_model=LiveScanFinished)
async def finish_live_scan(scan_id: str, session: DbSession, user: CurrentUser) -> LiveScanFinished:
    dictionary = await load_dictionary(session)
    return await live_scan.finish(session, user, _scan_id(scan_id), dictionary, _now())
