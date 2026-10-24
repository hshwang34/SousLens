"""Cooking sessions (COOK-01..08, brief 005 contract). Owner only: a foreign session id and a
missing one return the identical 404."""

from __future__ import annotations

import uuid
from typing import Annotated, Literal

from fastapi import APIRouter, Header, Query, Request, Response, status
from fastapi.responses import JSONResponse

from app.ai.providers.base import AIProvider
from app.core.errors import NotFound
from app.core.security import CurrentUser, SettingsDep
from app.db.engine import DbSession
from app.domains.sessions import ask as ask_service
from app.domains.sessions import service
from app.domains.sessions.schemas import (
    AskIn,
    AskOut,
    CommandIn,
    NoteIn,
    NoteOut,
    SessionCreateIn,
    SessionList,
    SessionOut,
)

router = APIRouter(prefix="/sessions", tags=["sessions"])

IdempotencyKey = Annotated[str, Header(alias="Idempotency-Key", pattern=r"^[\x21-\x7e]{1,128}$")]


OptionalIdempotencyKey = Annotated[
    str | None, Header(alias="Idempotency-Key", pattern=r"^[\x21-\x7e]{1,128}$")
]


def _session_id(value: str) -> uuid.UUID:
    try:
        return uuid.UUID(value)
    except ValueError as exc:
        raise NotFound("Session not found") from exc


@router.post("", response_model=SessionOut, status_code=status.HTTP_201_CREATED)
async def create_session(
    body: SessionCreateIn, session: DbSession, user: CurrentUser, settings: SettingsDep
) -> SessionOut:
    return await service.create(session, user, body, settings.share_url_base)


@router.get("", response_model=SessionList)
async def list_sessions(
    session: DbSession,
    user: CurrentUser,
    status_filter: Annotated[Literal["active"] | None, Query(alias="status")] = None,
) -> SessionList:
    """``?status=active`` → created/active/paused, newest first (resume banner)."""
    items = await service.list_sessions(session, user, active_only=status_filter == "active")
    return SessionList(items=items)


@router.get("/{session_id}", response_model=SessionOut)
async def get_session(
    session_id: str, session: DbSession, user: CurrentUser, settings: SettingsDep
) -> SessionOut:
    return await service.get(session, user, _session_id(session_id), settings.share_url_base)


@router.delete("/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_session(session_id: str, session: DbSession, user: CurrentUser) -> Response:
    await service.delete(session, user, _session_id(session_id))
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/{session_id}/commands", response_model=SessionOut)
async def run_command(
    session_id: str,
    body: CommandIn,
    idempotency_key: IdempotencyKey,
    session: DbSession,
    user: CurrentUser,
    settings: SettingsDep,
) -> JSONResponse:
    """Step Oracle commands (PRD §11.1). A replayed key returns the stored response verbatim."""
    payload = await service.run_command(
        session, user, _session_id(session_id), idempotency_key, body, settings.share_url_base
    )
    return JSONResponse(content=payload)


@router.post("/{session_id}/ask", response_model=AskOut)
async def ask(
    session_id: str, body: AskIn, request: Request, session: DbSession, user: CurrentUser
) -> AskOut:
    provider: AIProvider = request.app.state.ai_provider
    return await ask_service.ask(session, user, _session_id(session_id), body, provider)


@router.post("/{session_id}/notes", response_model=NoteOut, status_code=status.HTTP_201_CREATED)
async def add_note(
    session_id: str,
    body: NoteIn,
    session: DbSession,
    user: CurrentUser,
    idempotency_key: OptionalIdempotencyKey = None,
) -> NoteOut:
    """Optional ``Idempotency-Key``: a retry returns the same note (201), no second row."""
    return await service.add_note(session, user, _session_id(session_id), body, idempotency_key)
