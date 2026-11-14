"""Voice recipe capture (brief 014). Owner only: a foreign session id and a missing one return
the identical 404. Writes take an ``Idempotency-Key`` (optional on create); a retry with the same
key and body replays the first response, a different body is a 409. Audio is never accepted."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Header, Request, Response, status
from fastapi.responses import JSONResponse

from app.ai.guard import provider_for
from app.core.security import CurrentUser, SettingsDep
from app.db.engine import DbSession
from app.domains.capture import service
from app.domains.capture.schemas import (
    CommandIn,
    FinishIn,
    FinishOut,
    QuestionOutcomeIn,
    QuestionOutcomeOut,
    SessionCreateIn,
    SessionOut,
    TurnsIn,
    TurnsOut,
)
from app.domains.extraction import jobs

router = APIRouter(prefix="/capture/sessions", tags=["capture"])

_KEY = r"^[\x21-\x7e]{1,128}$"
IdempotencyKey = Annotated[str, Header(alias="Idempotency-Key", pattern=_KEY)]
OptionalIdempotencyKey = Annotated[str | None, Header(alias="Idempotency-Key", pattern=_KEY)]


@router.post("", response_model=SessionOut, status_code=status.HTTP_201_CREATED)
async def create_session(
    body: SessionCreateIn,
    session: DbSession,
    user: CurrentUser,
    idempotency_key: OptionalIdempotencyKey = None,
) -> JSONResponse:
    row, created = await service.create(session, user, body, idempotency_key)
    return JSONResponse(
        content=service.to_session_out(row).model_dump(mode="json"),
        status_code=status.HTTP_201_CREATED if created else status.HTTP_200_OK,
    )


@router.get("/{session_id}", response_model=SessionOut)
async def get_session(session_id: str, session: DbSession, user: CurrentUser) -> SessionOut:
    """The session and its events, for resuming after a relaunch."""
    return await service.get(session, user, service.session_id_or_404(session_id))


@router.delete("/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_session(session_id: str, session: DbSession, user: CurrentUser) -> Response:
    await service.delete(session, user, service.session_id_or_404(session_id))
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/{session_id}/turns", response_model=TurnsOut)
async def post_turns(
    session_id: str,
    body: TurnsIn,
    idempotency_key: IdempotencyKey,
    request: Request,
    session: DbSession,
    user: CurrentUser,
) -> JSONResponse:
    sid = service.session_id_or_404(session_id)
    out = await service.turns(
        session, user, sid, idempotency_key, body, provider_for(request, user.id)
    )
    return JSONResponse(content=out)


@router.post("/{session_id}/questions/{question_id}", response_model=QuestionOutcomeOut)
async def post_question_outcome(
    session_id: str,
    question_id: str,
    body: QuestionOutcomeIn,
    idempotency_key: IdempotencyKey,
    session: DbSession,
    user: CurrentUser,
) -> JSONResponse:
    sid = service.session_id_or_404(session_id)
    out = await service.question_outcome(session, user, sid, question_id, idempotency_key, body)
    return JSONResponse(content=out)


@router.post("/{session_id}/commands", response_model=SessionOut)
async def post_command(
    session_id: str,
    body: CommandIn,
    idempotency_key: IdempotencyKey,
    session: DbSession,
    user: CurrentUser,
) -> JSONResponse:
    sid = service.session_id_or_404(session_id)
    return JSONResponse(content=await service.command(session, user, sid, idempotency_key, body))


@router.post("/{session_id}/finish", response_model=FinishOut)
async def post_finish(
    session_id: str,
    idempotency_key: IdempotencyKey,
    request: Request,
    session: DbSession,
    user: CurrentUser,
    body: FinishIn | None = None,
) -> JSONResponse:
    sid = service.session_id_or_404(session_id)
    out = await service.finish(
        session, user, sid, idempotency_key, body or FinishIn(), provider_for(request, user.id)
    )
    return JSONResponse(content=out)


@router.post(
    "/{session_id}/generate", response_model=jobs.JobOut, status_code=status.HTTP_202_ACCEPTED
)
async def post_generate(
    session_id: str,
    idempotency_key: IdempotencyKey,
    request: Request,
    session: DbSession,
    user: CurrentUser,
    settings: SettingsDep,
) -> jobs.JobOut:
    job = await service.generate(
        session,
        user,
        service.session_id_or_404(session_id),
        idempotency_key,
        settings=settings,
        provider=request.app.state.ai_provider,
        guard=request.app.state.cost_guard,
    )
    return jobs.to_job_out(job)
