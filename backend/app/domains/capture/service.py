"""Voice capture sessions (brief 014): sessions, timestamped events, the interviewer loop,
wrap-up and draft generation.

* Owner only: a foreign session and a missing one are the identical 404
  (``get_owned_or_404``). Every write locks the session row, so one session's requests
  serialise; writes take an ``Idempotency-Key`` and a retry replays the stored response.
* The interviewer is only called when the ask gate is open (a pause, nobody speaking, budget
  and spacing left), so a creator mid-sentence never costs an AI call. ``policy`` decides.
* No audio is ever accepted or stored, only transcript text.
"""

from __future__ import annotations

import hashlib
import json
import logging
import time
import uuid
from datetime import UTC, datetime
from typing import Any

from pydantic import BaseModel
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.budget import CostGuard
from app.ai.providers.base import (
    CaptureGapState,
    CaptureInterviewer,
    CaptureInterviewRequest,
    CaptureUtterance,
)
from app.ai.providers.gemini import GeminiProvider
from app.core.config import Settings
from app.core.errors import (
    AIResting,
    AppError,
    CaptureGenerationLimit,
    CaptureModeUnavailable,
    NotFound,
    RateLimited,
    StateConflict,
    ValidationError,
)
from app.db.models import (
    CaptureEvent,
    CaptureRequest,
    CaptureSession,
    DraftStatus,
    ExtractionJob,
    ExtractionStatus,
    RecipeDraft,
    User,
)
from app.domains.capture import policy
from app.domains.capture.policy import Ask, Ledger
from app.domains.capture.schemas import (
    AskOut,
    CommandIn,
    EventOut,
    FinishIn,
    FinishOut,
    PolicyOut,
    QuestionOutcomeIn,
    QuestionOutcomeOut,
    SessionCreateIn,
    SessionOut,
    TurnsIn,
    TurnsOut,
)
from app.domains.extraction import jobs
from app.domains.media import service as media
from app.domains.ownership import get_owned_or_404
from app.domains.recipes import drafts
from app.domains.recipes.draft_schemas import DraftContent, DraftExtraction

log = logging.getLogger("umma.capture")

OPEN_STATUSES = ("recording", "wrapping_up")
MAX_OPEN_SESSIONS = 3
MAX_EVENTS = 5000
WINDOW_MAX = 200  # utterances sent to the interviewer per pause
RECENT_MAX = 20  # earlier utterances sent along as context
INFLIGHT_SECONDS = 30.0  # an interviewer claim lapses after this, even if its worker died
INTERVIEWER_BACKOFF_MS = 10_000  # phone time to wait after a failed interviewer call
FINAL_SWEEP_MAX = 2000


def _now() -> datetime:
    return datetime.now(UTC)


def request_hash(body: BaseModel | dict[str, Any]) -> str:
    data = body.model_dump(mode="json") if isinstance(body, BaseModel) else body
    canonical = json.dumps(data, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def session_id_or_404(value: str) -> uuid.UUID:
    try:
        return uuid.UUID(value)
    except ValueError as exc:
        raise NotFound("Capture session not found") from exc


async def _owned(
    session: AsyncSession, user: User, session_id: uuid.UUID, *, lock: bool = False
) -> CaptureSession:
    if not lock:
        return await get_owned_or_404(
            session, CaptureSession, session_id, user.id, label="Capture session"
        )
    # Locked re-select: a row deleted under us is the same 404 as a missing or foreign one.
    stmt = (
        select(CaptureSession)
        .where(CaptureSession.id == session_id, CaptureSession.owner_user_id == user.id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    row = (await session.execute(stmt)).scalar_one_or_none()
    if row is None:
        raise NotFound("Capture session not found")
    return row


def _ledger(row: CaptureSession) -> Ledger:
    return Ledger.model_validate(row.state_json or {})


def _save(row: CaptureSession, ledger: Ledger) -> None:
    row.state_json = ledger.model_dump(mode="json")
    row.updated_at = _now()


def _ask_out(ask: Ask) -> AskOut:
    return AskOut(
        question_id=uuid.UUID(ask.question_id),
        text=ask.text,
        topic_key=ask.topic_key,
        topic=ask.topic,
        phase=ask.phase,
        expires_at_ms=ask.expires_at_ms,
    )


def to_session_out(row: CaptureSession, events: list[CaptureEvent] | None = None) -> SessionOut:
    ledger = _ledger(row)
    pending = ledger.pending
    pending_out = None
    if pending is not None:
        gap = ledger.gaps.get(pending.topic_key)
        pending_out = AskOut(
            question_id=uuid.UUID(pending.question_id),
            text=pending.text,
            topic_key=pending.topic_key,
            topic=gap.topic if gap else "time",
            phase=pending.phase,
            expires_at_ms=pending.expires_at_ms,
        )
    return SessionOut(
        id=row.id,
        mode=row.mode,
        status=row.status,
        title_hint=row.title_hint,
        draft_id=row.draft_id,
        extraction_job_id=row.extraction_job_id,
        asking_stopped=ledger.quiet,
        paused=ledger.paused,
        live_asks_used=ledger.live_asks,
        pending_question=pending_out,
        wrapup_questions=[_ask_out(a) for a in policy.open_wrapup_questions(ledger)],
        transcript_deleted=row.transcript_purged_at is not None,
        policy=PolicyOut(),
        started_at=row.started_at,
        ended_at=row.ended_at,
        created_at=row.created_at,
        updated_at=row.updated_at,
        events=None
        if events is None
        else [
            EventOut(
                id=e.id,
                t_ms=e.t_ms,
                kind=e.kind,
                text=e.text,
                topic_key=e.topic_key,
                question_id=e.question_id,
            )
            for e in events
        ],
    )


# --- idempotency --------------------------------------------------------------------------


async def _replay(
    session: AsyncSession, row: CaptureSession, key: str, digest: str
) -> dict[str, Any] | None:
    prior = (
        await session.execute(
            select(CaptureRequest).where(
                CaptureRequest.session_id == row.id, CaptureRequest.idempotency_key == key
            )
        )
    ).scalar_one_or_none()
    if prior is None:
        return None
    if prior.request_hash != digest:
        raise StateConflict("This Idempotency-Key was already used for a different request")
    return prior.response_json


def _remember(
    session: AsyncSession, row: CaptureSession, key: str, digest: str, response: dict[str, Any]
) -> None:
    session.add(
        CaptureRequest(
            session_id=row.id, idempotency_key=key, request_hash=digest, response_json=response
        )
    )


def _event(row: CaptureSession, t_ms: int, kind: str, text: str = "", **kw: Any) -> CaptureEvent:
    return CaptureEvent(session_id=row.id, t_ms=t_ms, kind=kind, text=text, **kw)


def _require_open(row: CaptureSession) -> None:
    if row.status not in OPEN_STATUSES:
        raise StateConflict("This recording has finished")


# --- create / read / delete ---------------------------------------------------------------


async def create(
    session: AsyncSession, user: User, body: SessionCreateIn, key: str | None
) -> tuple[CaptureSession, bool]:
    if body.mode == "camera":
        raise CaptureModeUnavailable(
            "Recording with the camera is coming soon. Record with your voice for now."
        )
    digest = request_hash(body)
    await media.lock_user_video(session, user.id)
    if key is not None:
        prior = (
            await session.execute(
                select(CaptureSession).where(
                    CaptureSession.owner_user_id == user.id, CaptureSession.idempotency_key == key
                )
            )
        ).scalar_one_or_none()
        if prior is not None:
            if prior.request_hash != digest:
                raise StateConflict("This Idempotency-Key was already used for a different session")
            return prior, False
    open_count = await session.scalar(
        select(func.count())
        .select_from(CaptureSession)
        .where(CaptureSession.owner_user_id == user.id, CaptureSession.status.in_(OPEN_STATUSES))
    )
    if (open_count or 0) >= MAX_OPEN_SESSIONS:
        raise RateLimited("Finish or delete a recording before starting another one")
    row = CaptureSession(
        owner_user_id=user.id,
        mode=body.mode,
        status="recording",
        title_hint=body.title_hint or None,
        state_json=Ledger().model_dump(mode="json"),
        started_at=_now(),
        idempotency_key=key,
        request_hash=digest if key is not None else None,
    )
    session.add(row)
    await session.flush()
    await session.refresh(row)
    return row, True


async def events_of(session: AsyncSession, session_id: uuid.UUID) -> list[CaptureEvent]:
    stmt = (
        select(CaptureEvent)
        .where(CaptureEvent.session_id == session_id)
        .order_by(CaptureEvent.t_ms, CaptureEvent.seq)
    )
    return list((await session.execute(stmt)).scalars())


async def get(session: AsyncSession, user: User, session_id: uuid.UUID) -> SessionOut:
    row = await _owned(session, user, session_id)
    return to_session_out(row, await events_of(session, row.id))


async def delete(session: AsyncSession, user: User, session_id: uuid.UUID) -> None:
    row = await _owned(session, user, session_id, lock=True)
    if row.status == "generating":
        raise StateConflict("A draft is being made from this recording; wait for it to finish")
    await session.delete(row)  # events and replay rows cascade; the draft is kept
    await session.flush()


# --- the interviewer loop -----------------------------------------------------------------


async def _utterances(
    session: AsyncSession,
    row: CaptureSession,
    *,
    after_seq: int = 0,
    before_seq: int | None = None,
    limit: int,
) -> list[tuple[int, CaptureUtterance]]:
    """Utterances by insertion order (``seq``), newest ``limit`` of them, oldest first."""
    stmt = select(CaptureEvent.seq, CaptureEvent.t_ms, CaptureEvent.text).where(
        CaptureEvent.session_id == row.id,
        CaptureEvent.kind == "utterance",
        CaptureEvent.seq > after_seq,
    )
    if before_seq is not None:
        stmt = stmt.where(CaptureEvent.seq < before_seq)
    stmt = stmt.order_by(CaptureEvent.seq.desc()).limit(limit)
    rows = list((await session.execute(stmt)).all())
    return [(seq, CaptureUtterance(t_ms=t, text=text)) for seq, t, text in reversed(rows)]


def _speech(items: list[tuple[int, CaptureUtterance]]) -> list[CaptureUtterance]:
    return [u for _seq, u in items if not policy.parse_command(u.text)]


def _known(ledger: Ledger) -> list[CaptureGapState]:
    return [
        CaptureGapState(topic_key=g.topic_key, topic=g.topic, question=g.question, status=g.status)
        for g in ledger.gaps.values()
    ]


def _close_event(row: CaptureSession, q: policy.Question, answer: str | None) -> CaptureEvent:
    t = q.closed_t_ms or q.asked_t_ms
    qid = uuid.UUID(q.question_id)
    match q.outcome:
        case "answered":
            return _event(row, t, "answer", answer or "", topic_key=q.topic_key, question_id=qid)
        case "skipped":
            return _event(row, t, "skip", "skip", topic_key=q.topic_key, question_id=qid)
        case _:
            return _event(row, t, "marker", str(q.outcome), topic_key=q.topic_key, question_id=qid)


async def turns(
    session: AsyncSession,
    user: User,
    session_id: uuid.UUID,
    key: str,
    body: TurnsIn,
    interviewer: CaptureInterviewer,
) -> dict[str, Any]:
    """Store the segments and, at a pause, maybe ask. The interviewer is called with no lock
    held and no transaction open: the segments and a no-ask reply are committed first, then
    the row is re-locked and the policy re-checked before an ask is stored, so two
    overlapping requests can never both ask."""
    row = await _owned(session, user, session_id, lock=True)
    digest = request_hash(body)
    if (replayed := await _replay(session, row, key, digest)) is not None:
        return replayed
    _require_open(row)
    ledger = _ledger(row)
    finals = [s for s in body.segments if s.is_final and s.text]
    count = await session.scalar(
        select(func.count()).select_from(CaptureEvent).where(CaptureEvent.session_id == row.id)
    )
    if (count or 0) + len(finals) > MAX_EVENTS:
        raise ValidationError("This recording is too long; tap Done to finish it")
    for index, seg in enumerate(finals):
        session.add(_event(row, seg.t_ms, "utterance", seg.text, client_key=f"{key}:{index}"))
    # "Now" on the phone's clock; it never runs backwards.
    now_ms = max([body.t_ms or 0, *(s.t_ms for s in body.segments), ledger.latest_t_ms])
    policy.observe_time(ledger, now_ms)

    closed: str | None = policy.expire_pending(ledger, now_ms)
    if closed:
        session.add(_close_event(row, ledger.questions[closed], None))
    for seg in finals:  # spoken "skip" / "later" / "stop asking"
        command = policy.parse_command(seg.text)
        if command == "stop_asking" and not ledger.quiet:
            ledger.quiet = True
            session.add(_event(row, seg.t_ms, "marker", "stop_asking"))
        elif command in ("skip", "later") and ledger.pending is not None:
            outcome: policy.Outcome = "skipped" if command == "skip" else "later"
            q = policy.apply_outcome(ledger, ledger.pending.question_id, outcome, None, seg.t_ms)
            session.add(_close_event(row, q, None))
            closed = q.question_id

    def gate(led: Ledger, status: str) -> bool:
        return policy.gate_open(
            led,
            recording=status == "recording",
            now_ms=now_ms,
            silence_ms=body.silence_ms,
            assistant_speaking=body.assistant_speaking,
        )

    window: list[tuple[int, CaptureUtterance]] = []
    if gate(ledger, row.status) and _interviewer_free(ledger, now_ms):
        await session.flush()
        window = await _utterances(session, row, after_seq=ledger.seen_seq, limit=WINDOW_MAX)
        if _speech(window):
            # Claim the window before the lock goes: a concurrent turn sees nothing new (and
            # an active claim), so it never calls the AI for the same words.
            ledger.seen_seq = window[-1][0]
            ledger.interviewer_inflight_until = time.time() + INFLIGHT_SECONDS
    _save(row, ledger)
    response = TurnsOut(
        ask=None,
        stored=len(finals),
        closed_question_id=uuid.UUID(closed) if closed else None,
        asking_stopped=ledger.quiet,
    ).model_dump(mode="json")
    _remember(session, row, key, digest, response)
    await session.flush()
    if not _speech(window):
        return response

    recent = await _utterances(session, row, before_seq=window[0][0], limit=RECENT_MAX)
    request = CaptureInterviewRequest(
        window=_speech(window),
        recent=_speech(recent),
        known_gaps=_known(ledger),
        said_keys=ledger.said,
        title_hint=row.title_hint,
    )
    await session.commit()  # captions are safe; no lock is held while the AI thinks
    try:
        decision = await interviewer.decide(request)
    except Exception as exc:
        # Refused, failed or timed out: release the claim and back off briefly, so a failing
        # AI is neither retried on every turn nor able to wedge the session. (A cancelled or
        # crashed request leaves a claim that lapses after INFLIGHT_SECONDS.)
        await session.rollback()
        await _release_interviewer(session, user, session_id, backoff_from=now_ms)
        if isinstance(exc, AppError):
            log.warning("capture interviewer failed; no question this pause")
            return response
        raise

    row = await _owned(session, user, session_id, lock=True)
    ledger = _ledger(row)
    ledger.interviewer_inflight_until = None
    policy.merge_decision(ledger, decision, t_ms=window[-1][1].t_ms)
    ask: Ask | None = None
    if gate(ledger, row.status):  # re-checked under the lock: still no open question etc.
        qid = uuid.uuid4()
        ask = policy.decide_live_ask(
            ledger,
            decision,
            question_id=str(qid),
            recording=row.status == "recording",
            now_ms=now_ms,
            silence_ms=body.silence_ms,
            assistant_speaking=body.assistant_speaking,
        )
        if ask is not None:
            session.add(
                CaptureEvent(
                    id=qid,
                    session_id=row.id,
                    t_ms=now_ms,
                    kind="question",
                    text=ask.text,
                    topic_key=ask.topic_key,
                )
            )
            response = {**response, "ask": _ask_out(ask).model_dump(mode="json")}
            await session.execute(
                update(CaptureRequest)
                .where(CaptureRequest.session_id == row.id, CaptureRequest.idempotency_key == key)
                .values(response_json=response)
            )
    _save(row, ledger)
    await session.flush()
    return response


def _interviewer_free(ledger: Ledger, now_ms: int) -> bool:
    if now_ms < ledger.interviewer_backoff_until_t_ms:
        return False
    until = ledger.interviewer_inflight_until
    return until is None or until <= time.time()


async def _release_interviewer(
    session: AsyncSession, user: User, session_id: uuid.UUID, *, backoff_from: int
) -> None:
    try:
        row = await _owned(session, user, session_id, lock=True)
    except NotFound:
        return
    ledger = _ledger(row)
    ledger.interviewer_inflight_until = None
    ledger.interviewer_backoff_until_t_ms = backoff_from + INTERVIEWER_BACKOFF_MS
    _save(row, ledger)
    await session.commit()


async def question_outcome(
    session: AsyncSession,
    user: User,
    session_id: uuid.UUID,
    question_id: str,
    key: str,
    body: QuestionOutcomeIn,
) -> dict[str, Any]:
    row = await _owned(session, user, session_id, lock=True)
    digest = request_hash({**body.model_dump(mode="json"), "question_id": question_id})
    if (replayed := await _replay(session, row, key, digest)) is not None:
        return replayed
    _require_open(row)
    if body.outcome == "answered" and not body.answer_text:
        raise ValidationError(
            "answer_text is required to answer", extra={"fields": ["answer_text"]}
        )
    ledger = _ledger(row)
    qid = str(uuid.UUID(question_id)) if _is_uuid(question_id) else ""
    if qid not in ledger.questions:
        raise NotFound("Question not found")
    current = ledger.questions[qid]
    if current.outcome == "expired":
        outcome: policy.Outcome = "expired"  # already expired by a turn: same answer, any order
        q = current
    elif current.outcome is not None:
        raise StateConflict("This question was already closed")
    else:
        # Past its expiry is expired, whichever call arrives first; t_ms is clamped.
        outcome, t_ms = policy.resolve_outcome(ledger, qid, body.outcome, body.t_ms)
        answer = body.answer_text if outcome == "answered" else None
        q = policy.apply_outcome(ledger, qid, outcome, answer, t_ms)
        session.add(_close_event(row, q, answer))
    _save(row, ledger)
    response = QuestionOutcomeOut(
        question_id=uuid.UUID(qid), topic_key=q.topic_key, outcome=outcome
    ).model_dump(mode="json")
    _remember(session, row, key, digest, response)
    await session.flush()
    return response


def _is_uuid(value: str) -> bool:
    try:
        uuid.UUID(value)
    except ValueError:
        return False
    return True


async def command(
    session: AsyncSession, user: User, session_id: uuid.UUID, key: str, body: CommandIn
) -> dict[str, Any]:
    row = await _owned(session, user, session_id, lock=True)
    digest = request_hash(body)
    if (replayed := await _replay(session, row, key, digest)) is not None:
        return replayed
    _require_open(row)
    ledger = _ledger(row)
    if body.command == "stop_asking":
        ledger.quiet = True
    else:
        ledger.paused = body.command == "pause"
    t_ms = ledger.latest_t_ms if body.t_ms is None else policy.clamp_t_ms(ledger, body.t_ms)
    session.add(_event(row, t_ms, "marker", body.command))
    _save(row, ledger)
    await session.flush()
    response = to_session_out(row).model_dump(mode="json")
    _remember(session, row, key, digest, response)
    return response


async def finish(
    session: AsyncSession,
    user: User,
    session_id: uuid.UUID,
    key: str,
    body: FinishIn,
    interviewer: CaptureInterviewer,
) -> dict[str, Any]:
    """Done: one last sweep for gaps, then at most 3 wrap-up questions. Calling it again
    (wrapping up already) returns the wrap-up questions still open. Like ``turns``, the
    interviewer runs with no lock held; the state is re-checked under the lock after."""
    row = await _owned(session, user, session_id, lock=True)
    digest = request_hash(body)
    if (replayed := await _replay(session, row, key, digest)) is not None:
        return replayed
    _require_open(row)
    if row.status == "recording":
        ledger = _ledger(row)
        everything = _speech(await _utterances(session, row, limit=FINAL_SWEEP_MAX))
        now_ms = max([body.t_ms or 0, ledger.latest_t_ms, *(u.t_ms for u in everything)])
        policy.observe_time(ledger, now_ms)
        if ledger.pending is not None:
            q = policy.apply_outcome(ledger, ledger.pending.question_id, "expired", None, now_ms)
            session.add(_close_event(row, q, None))
        _save(row, ledger)
        request = CaptureInterviewRequest(
            window=everything,
            known_gaps=_known(ledger),
            said_keys=ledger.said,
            title_hint=row.title_hint,
            final=True,
        )
        await session.commit()  # no lock is held while the AI thinks
        decision = None
        if everything:
            try:
                decision = await interviewer.decide(request)
            except AppError:
                log.warning("capture interviewer failed; wrap-up uses the gaps already noted")
        row = await _owned(session, user, session_id, lock=True)
        if (replayed := await _replay(session, row, key, digest)) is not None:
            return replayed
        _require_open(row)
        if row.status == "recording":  # nobody else finished it meanwhile
            ledger = _ledger(row)
            if decision is not None:
                policy.merge_decision(ledger, decision, t_ms=everything[-1].t_ms)
            ids = [uuid.uuid4() for _ in range(policy.DEFAULT_POLICY.max_wrapup_questions)]
            for ask in policy.pick_wrapup_questions(ledger, map(str, ids), now_ms=now_ms):
                session.add(
                    CaptureEvent(
                        id=uuid.UUID(ask.question_id),
                        session_id=row.id,
                        t_ms=now_ms,
                        kind="question",
                        text=ask.text,
                        topic_key=ask.topic_key,
                    )
                )
            row.status = "wrapping_up"
            row.ended_at = _now()
            _save(row, ledger)
    await session.flush()
    out = to_session_out(row)
    response = FinishOut(questions=out.wrapup_questions, session=out).model_dump(mode="json")
    _remember(session, row, key, digest, response)
    return response


# --- generate -----------------------------------------------------------------------------


async def generate(
    session: AsyncSession,
    user: User,
    session_id: uuid.UUID,
    key: str,
    *,
    settings: Settings,
    provider: object,
    guard: CostGuard,
) -> ExtractionJob:
    """Queue the draft: a draft (``extracting``) and an ``ExtractionJob`` of kind ``capture``,
    polled through ``GET /v1/extractions/{job_id}``. Over a cap it refuses (retryable) and
    the recording is kept untouched."""
    row = await _owned(session, user, session_id, lock=True)
    digest = request_hash({"generate": True})
    if (replayed := await _replay(session, row, key, digest)) is not None:
        return await jobs.get_job(session, user, uuid.UUID(replayed["job_id"]))
    if row.status == "recording":
        raise StateConflict("Tap Done to finish the recording first")
    if row.status not in ("wrapping_up", "failed"):
        raise StateConflict("A draft was already made from this recording")
    if row.transcript_purged_at is not None:
        raise StateConflict("This recording's transcript was deleted")
    await media.lock_user_video(session, user.id)
    if isinstance(provider, GeminiProvider):
        if not provider.configured:
            raise provider.unavailable("capture")
        if (await guard.status(None)).reason == "monthly_cap":
            raise AIResting(
                "AI is resting for the rest of the month. Your recording is saved: make the "
                "draft later, or type the recipe in."
            )
    limit = settings.ai_user_video_extractions_per_month
    used = await jobs.monthly_extractions(session, user.id)
    if used >= limit:
        raise CaptureGenerationLimit(
            f"You've used all {limit} AI recipe drafts this month. Your recording is saved: "
            "make the draft next month, or type the recipe in.",
            extra={"details": {"limit": limit, "used": used}},
        )
    ledger = _ledger(row)
    for q in policy.open_wrapup_questions(ledger):  # unanswered wrap-up questions stay unknowns
        closed = policy.apply_outcome(ledger, q.question_id, "expired", None, q.expires_at_ms or 0)
        session.add(_close_event(row, closed, None))
    _save(row, ledger)

    job_id = uuid.uuid4()
    content = DraftContent(title=row.title_hint, extraction=DraftExtraction(job_id=job_id))
    draft = await session.get(RecipeDraft, row.draft_id) if row.draft_id else None
    if draft is None or draft.status != DraftStatus.EDITING or draft.owner_user_id != user.id:
        draft = RecipeDraft(owner_user_id=user.id, status=DraftStatus.EXTRACTING)
        session.add(draft)
    draft.structured_draft_json = drafts.normalise(content)
    draft.status = DraftStatus.EXTRACTING
    await session.flush()
    job = ExtractionJob(
        id=job_id,
        owner_user_id=user.id,
        draft_id=draft.id,
        kind="capture",
        status=ExtractionStatus.QUEUED,
        attempts=0,
        progress=0,
        stage="queued",
        params_json={"capture_session_id": str(row.id), "title_hint": row.title_hint},
        counts_toward_limit=True,
    )
    session.add(job)
    row.status = "generating"
    row.draft_id = draft.id
    await session.flush()
    row.extraction_job_id = job.id
    _remember(session, row, key, digest, {"job_id": str(job.id)})
    await session.flush()
    await session.refresh(job)
    return job
