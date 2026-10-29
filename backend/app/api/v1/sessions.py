"""Cooking sessions (COOK-01..08, brief 005 contract). Owner only: a foreign session id and a
missing one return the identical 404."""

from __future__ import annotations

import uuid
from typing import Annotated, Literal

import pydantic
from fastapi import APIRouter, Header, Query, Request, Response, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from app.ai.guard import notice_of, provider_for
from app.core.errors import NotFound, UnsupportedMediaType, ValidationError
from app.core.security import CurrentUser, SettingsDep
from app.db.engine import DbSession
from app.domains.pantry import upload
from app.domains.sessions import ask as ask_service
from app.domains.sessions import inspect as inspect_service
from app.domains.sessions import service
from app.domains.sessions.schemas import (
    QUERY_MAX,
    AskIn,
    AskOut,
    CommandIn,
    InspectOut,
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
    provider = provider_for(request, user.id)
    out = await ask_service.ask(session, user, _session_id(session_id), body, provider)
    out.ai_notice = notice_of(provider)
    return out


_INSPECT_BODY = {
    "requestBody": {
        "required": True,
        "content": {
            "multipart/form-data": {
                "schema": {
                    "type": "object",
                    "required": ["image", "query"],
                    "properties": {
                        "image": {"type": "string", "format": "binary"},
                        "query": {"type": "string", "maxLength": QUERY_MAX},
                        "grounded_revision": {"type": "integer", "minimum": 0},
                        "captured_at": {"type": "string", "maxLength": 64},
                    },
                }
            }
        },
    }
}


def _revision_field(value: str | None) -> int | None:
    if value is None or value == "":
        return None
    if not value.isdigit() or len(value) > 9:
        raise ValidationError(
            "grounded_revision must be a non-negative integer",
            extra={"fields": ["grounded_revision"]},
        )
    return int(value)


@router.post("/{session_id}/inspect", response_model=InspectOut, openapi_extra=_INSPECT_BODY)
async def inspect(
    session_id: str, request: Request, session: DbSession, user: CurrentUser
) -> InspectOut:
    """One user-initiated photo for the current step (brief 007). The photo is processed in
    memory and never stored or logged."""
    sid = _session_id(session_id)
    content_type = request.headers.get("content-type", "")
    if content_type.split(";", 1)[0].strip().lower() != "multipart/form-data":
        raise UnsupportedMediaType("Send the photo as multipart/form-data")
    body = await upload.read_body_capped(request)
    parts = upload.parse_multipart(body, content_type)
    del body
    image = parts.get("image")
    if image is None or image.filename is None or not image.data:
        raise ValidationError("an image file is required", extra={"fields": ["image"]})
    data = bytes(image.data)
    image.data.clear()
    mime = upload.sniff_image(data)
    try:  # the same text rules as /ask (length, control characters, trimming)
        query = AskIn(query=upload.text_field(parts, "query") or "").query
    except pydantic.ValidationError as exc:
        raise RequestValidationError(exc.errors()) from exc
    captured_at = upload.text_field(parts, "captured_at")
    if captured_at is not None and len(captured_at) > 64:
        raise ValidationError("captured_at is too long", extra={"fields": ["captured_at"]})
    provider = provider_for(request, user.id)
    try:
        out = await inspect_service.inspect(
            session,
            user,
            sid,
            query=query,
            grounded_revision=_revision_field(upload.text_field(parts, "grounded_revision")),
            captured_at=captured_at or None,
            image=data,
            mime_type=mime,
            provider=provider,
        )
    finally:
        del data  # PRIV-01: the photo lives only for this request
    out.ai_notice = notice_of(provider)
    return out


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
