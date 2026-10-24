"""``POST /sessions/{id}/ask`` (COOK-03/04, PRD §8.5, Appendix A, brief 005 contract).

* The grounding packet holds only what §8.5 allows: the pinned version's title, servings and
  original ingredient amounts, the current step ± 1, creator notes and warnings, approved
  adaptations, the session's relevant pantry subset, the last 10 turns, running timers and the
  caller's food preferences.
* Recipe text, notes and the query are untrusted data. The coach never changes state; its
  ``proposed_action`` is kept only when the user's own query asked for it and it is legal right
  now, and it always ``requires_confirmation``.
* Deterministic safety wins over the coach (DECISIONS #15): a doneness / safe-to-eat question
  or a raw-tasting question is answered from a fixed template (the step's cues, the
  thermometer / verified-guidance notice, "I can't tell from a description or photo") and the
  model is not called at all. Every other model answer is post-filtered as a second line of
  defence: when the query or answer touches doneness / safety / readiness, every sentence that
  could certify it is dropped, the thermometer notice is attached, and an emptied answer
  falls back to the template.
* Rate limits: 120 asks per user per hour across all sessions (``usage_events``, survives
  session deletion) and 60 per session per hour; both reserved and committed before the
  provider call so no lock spans it.
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from datetime import UTC, datetime, timedelta

import pydantic
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.providers.base import (
    ApprovedSubstitution,
    CoachRequest,
    CoachResponse,
    CookingCoach,
    IngredientSummary,
    StepSummary,
    TimerSummary,
    TranscriptTurn,
)
from app.core.errors import (
    AppError,
    InvalidTransition,
    NotFound,
    ProviderOutputInvalid,
    ProviderUnavailable,
    RateLimited,
)
from app.db.models import CookingSession, MessageRole, SessionMessage, User
from app.domains import usage
from app.domains.recipes.schemas import IngredientOut, StepOut
from app.domains.safety.content import (
    CANT_TELL,
    DONENESS_NOTICE,
    RAW_TASTING_NOTICE,
    doneness_notice,
    is_doneness_question,
    is_high_risk,
    is_raw_tasting_request,
    is_temperature_question,
    mentions_safety_terms,
    strip_certifications,
    temperature_table,
)
from app.domains.sessions import intent, service
from app.domains.sessions.schemas import (
    AskIn,
    AskOut,
    GroundingOut,
    ProposedActionOut,
    ProposedTimer,
)
from app.domains.substitutions.adapt import suggested_timer
from app.domains.substitutions.service import context_from
from app.domains.users import preferences

log = logging.getLogger("souslens.sessions.ask")

RATE_LIMIT_PER_HOUR = 60  # per session (secondary cap)
USER_ASKS_PER_HOUR = 120  # per user, across sessions (primary)
RECENT_TURNS = 10
PROVIDER_TIMEOUT_SECONDS = 20.0
MAX_TIMER_SECONDS = 24 * 3600
_GROUNDING_MAP = {
    "recipe_step": "recipe_step",
    "ingredient": "ingredient",
    "recipe_ingredient": "ingredient",
    "creator_note": "creator_note",
    "adaptation": "adaptation",
    "substitution": "adaptation",
}


def _amount(i: IngredientOut) -> str | None:
    if i.quantity is None:
        return None
    qty = f"{i.quantity:g}"
    return f"{qty} {i.unit}" if i.unit else qty


def _summary(step: StepOut, instruction: str | None = None) -> StepSummary:
    timer = suggested_timer(step.instruction, step.order)
    return StepSummary(
        id=step.id,
        order=step.order,
        instruction=instruction or step.instruction,
        success_cues=list(step.success_cues),
        warnings=list(step.warnings),
        creator_note=step.creator_note,
        source_clip_id=step.source_clip_id,
        ingredient_refs=list(step.ingredient_refs),
        suggested_timer_label=str(timer["label"]) if timer else None,
        suggested_timer_seconds=int(timer["duration_seconds"]) if timer else None,  # type: ignore[call-overload]
    )


async def _coach(provider: CookingCoach, request: CoachRequest) -> CoachResponse:
    for attempt in (1, 2):
        try:
            result = await asyncio.wait_for(
                provider.answer(request), timeout=PROVIDER_TIMEOUT_SECONDS
            )
            return CoachResponse.model_validate(
                result.model_dump(warnings=False)
                if isinstance(result, pydantic.BaseModel)
                else result
            )
        except pydantic.ValidationError as exc:
            if attempt == 2:
                raise ProviderOutputInvalid(
                    "The assistant's answer came back malformed; the step text is unchanged"
                ) from exc
        except AppError:
            raise
        except Exception as exc:
            log.warning("coach provider failed", extra={"error_type": type(exc).__name__})
            raise ProviderUnavailable(
                "The assistant is unavailable; the current step is shown as written"
            ) from exc
    raise AssertionError("unreachable")  # pragma: no cover


async def ask(
    session: AsyncSession,
    user: User,
    session_id: uuid.UUID,
    body: AskIn,
    provider: CookingCoach,
) -> AskOut:
    now = datetime.now(UTC)
    row = await service._owned(session, user, session_id, lock=True)
    if row.status.value in ("completed", "abandoned"):
        raise InvalidTransition(f"session is {row.status.value}; the assistant is closed")
    asked = await session.scalar(
        select(func.count())
        .select_from(SessionMessage)
        .where(
            SessionMessage.session_id == row.id,
            SessionMessage.role == MessageRole.USER,
            SessionMessage.created_at > now - timedelta(hours=1),
        )
    )
    if (asked or 0) >= RATE_LIMIT_PER_HOUR:
        raise RateLimited("Too many questions in the last hour for this session; try again later")
    # The primary budget is per user across all sessions, in a ledger that session deletion
    # cannot touch (brief 005 security review). Rolled back if anything below fails.
    await usage.reserve(
        session,
        user.id,
        usage.ASK,
        limit=USER_ASKS_PER_HOUR,
        window=timedelta(hours=1),
        now=now,
        message="Too many questions in the last hour; try again later",
    )

    version, recipe = await service._pinned(session, row)
    ctx = context_from(version, recipe)
    overlay = (row.adaptation_json or {}).get("steps", {})
    steps = ctx.steps
    idx = min(row.step_index, max(len(steps) - 1, 0))

    def summary(i: int) -> StepSummary | None:
        if 0 <= i < len(steps):
            entry = overlay.get(steps[i].id)
            return _summary(steps[i], entry["instruction"] if entry else None)
        return None

    adaptations = await service.active_adaptations(session, row.id)
    timers = [
        t
        for t in await service.session_timers(session, row.id)
        if service.timer_status(t, now) == "running"
    ]
    turns = list(
        (
            await session.execute(
                select(SessionMessage)
                .where(SessionMessage.session_id == row.id)
                .order_by(SessionMessage.created_at.desc(), SessionMessage.id.desc())
                .limit(RECENT_TURNS)
            )
        ).scalars()
    )[::-1]
    prof = await preferences.profile(session, user)
    names = {i.id: i.name for i in ctx.ingredients}
    packet = CoachRequest(
        recipe_id=str(ctx.recipe_id),
        recipe_version_id=str(ctx.version_id),
        version_number=version.version_number,
        title=ctx.title,
        servings=version.servings,
        ingredients=[" ".join(filter(None, [_amount(i), i.name])) for i in ctx.ingredients],
        ingredient_items=[
            IngredientSummary(id=i.id, name=i.name, amount=_amount(i)) for i in ctx.ingredients
        ],
        creator_notes=list(ctx.creator_notes),
        dietary_warnings=list(ctx.dietary_warnings),
        current_step=summary(idx),  # type: ignore[arg-type]
        previous_step=summary(idx - 1),
        next_step=summary(idx + 1),
        approved_substitutions=[
            ApprovedSubstitution(
                ingredient_id=a.ingredient_ref,
                replacement=a.replacement,
                reason=a.reason or "",
                adaptation_id=str(a.id),
                original=a.original,
                ratio_or_amount=a.ratio_or_amount,
            )
            for a in adaptations
        ],
        relevant_pantry=[p["normalized_name"] for p in row.pantry_snapshot_json],
        recent_turns=[
            TranscriptTurn(role=m.role.value, text=m.text)  # type: ignore[arg-type]
            for m in turns
            if m.role in (MessageRole.USER, MessageRole.ASSISTANT)
        ],
        active_timers=[
            TimerSummary(id=str(t.id), label=t.label, target_at=t.target_at.isoformat())
            for t in timers
        ],
        user_preferences=[
            *(f"allergy: {a}" for a in prof.allergy_labels),
            *(f"avoid: {a}" for a in prof.avoid_labels),
        ],
        session_revision=row.revision,
        query=body.query,
    )
    grounded_revision = row.revision
    grounded_step = idx

    # Reserve the rate-limit slot and release the row lock before the provider call.
    user_turn = SessionMessage(
        session_id=row.id,
        role=MessageRole.USER,
        text=body.query,
        grounded_step_index=grounded_step,
        grounded_revision=grounded_revision,
        source_refs_json=[],
        created_at=now,
    )
    session.add(user_turn)
    await session.commit()

    # Deterministic safety first (DECISIONS #15): a raw-tasting or doneness / safe-to-eat
    # question never reaches the model and never carries model prose.
    current = ctx.steps[idx]
    raw_context = [
        *(st.instruction for st in ctx.steps[: idx + 1]),
        *current.warnings,
        *names.values(),
    ]
    risk_context = [current.instruction, *current.warnings, *names.values()]
    if is_raw_tasting_request(body.query, raw_context):
        out = _template(packet, RAW_TASTING_NOTICE, refusal=True)
    elif is_temperature_question(body.query):
        table = temperature_table(body.query, risk_context)
        out = _template(packet, f"{DONENESS_NOTICE} {table}", refusal=True)
    elif is_doneness_question(body.query, risk_context):
        out = _template(packet, doneness_notice_for(body.query, risk_context), refusal=False)
    else:
        response = await _coach(provider, packet)
        out = _postprocess(response, body, packet, ctx.steps, names, idx, adaptations)
    current_revision = await session.scalar(
        select(CookingSession.revision).where(CookingSession.id == row.id)
    )
    if current_revision is None:
        raise NotFound("Session not found")  # deleted while the assistant was answering
    stale = (
        body.grounded_revision is not None and body.grounded_revision != grounded_revision
    ) or (current_revision != grounded_revision)
    reply = SessionMessage(
        session_id=row.id,
        role=MessageRole.ASSISTANT,
        text=out["answer_text"],
        grounded_step_index=grounded_step,
        grounded_revision=grounded_revision,
        source_refs_json=[g.model_dump() for g in out["grounding"]],
        created_at=datetime.now(UTC),
    )
    session.add(reply)
    try:
        await session.flush()
    except IntegrityError as exc:  # the session was deleted between the check and the insert
        raise NotFound("Session not found") from exc
    return AskOut(
        message_id=reply.id,
        grounded_session_revision=grounded_revision,
        stale=stale,
        **out,
    )


def _postprocess(
    response: CoachResponse,
    body: AskIn,
    packet: CoachRequest,
    steps: list[StepOut],
    names: dict[str, str],
    idx: int,
    adaptations: list,
) -> dict:
    current = packet.current_step
    answer = response.answer_text.strip()
    safety_notice = response.safety_notice
    uncertainty = response.uncertainty
    proposed = _gate_action(response, body.query, len(steps), idx, current)

    known = {
        "recipe_step": {s.id for s in (packet.previous_step, current, packet.next_step) if s},
        "ingredient": set(names),
        "creator_note": {s.id for s in (packet.previous_step, current, packet.next_step) if s}
        | {f"note-{i + 1}" for i in range(len(packet.creator_notes))},
        "adaptation": {str(a.id) for a in adaptations},
    }
    grounding: list[GroundingOut] = []
    for ref in response.grounding:
        kind = _GROUNDING_MAP.get(ref.type)
        if kind is None or ref.id not in known[kind]:
            continue  # visual refs arrive in Slice 4; unknown ids are never passed through
        g = GroundingOut(type=kind, id=ref.id)  # type: ignore[arg-type]
        if g not in grounding:
            grounding.append(g)
    if not grounding:
        grounding.append(GroundingOut(type="recipe_step", id=current.id))

    # Second line of defence on EVERY model answer: a question the detectors missed must never
    # come back with a sentence certifying doneness or safety, or a bare "Yes!" at a high-risk
    # step (security reviews of bab9b53 and 279b861).
    context = [current.instruction, *current.warnings, *names.values()]
    touched = mentions_safety_terms(body.query) or mentions_safety_terms(answer)
    answer, dropped = strip_certifications(answer, high_risk=is_high_risk(context))
    if touched or dropped:
        notice = doneness_notice_for(body.query, context)
        if not answer:
            return _template(packet, notice, refusal=False)
        safety_notice = notice
        uncertainty = "high" if uncertainty == "high" else "medium"
    return {
        "answer_text": answer,
        "grounding": grounding,
        "uncertainty": uncertainty,
        "safety_notice": safety_notice,
        "proposed_action": proposed,
        "requires_confirmation": proposed is not None,
    }


def _template(packet: CoachRequest, notice: str, *, refusal: bool) -> dict:
    """The fixed answer for safety questions: the creator's cues, the notice, nothing else."""
    step = packet.current_step
    cues = "; ".join(step.success_cues) if step.success_cues else step.instruction
    said = f"The recipe says (step {step.order + 1}): {cues.rstrip('.')}."
    answer = (
        f"{said} My suggestion: {notice}"
        if refusal
        else f"{said} My suggestion: {notice} {CANT_TELL}"
    )
    return {
        "answer_text": answer,
        "grounding": [GroundingOut(type="recipe_step", id=step.id)],
        "uncertainty": "high",
        "safety_notice": notice,
        "proposed_action": None,
        "requires_confirmation": False,
    }


def doneness_notice_for(query: str, context: list[str]) -> str:
    return doneness_notice(query, context) or DONENESS_NOTICE


def _gate_action(
    response: CoachResponse, query: str, steps_count: int, idx: int, current: StepSummary
) -> ProposedActionOut | None:
    """Keep a proposal only if the user's own words asked for it. Its ARGUMENTS also come only
    from the query or the step's suggested timer, never from the model (item 6)."""
    action = response.proposed_action
    if action is None or action.command not in intent.intents(query):
        return None  # only what the user asked for; recipe text can never propose
    last = max(steps_count - 1, 0)
    if action.command == "next":
        return ProposedActionOut(command="next") if idx < last else None
    if action.command == "back":
        return ProposedActionOut(command="back") if idx > 0 else None
    if action.command == "jump_to_step":
        target = intent.jump_target(query)
        if target is None or not (0 <= target <= last) or target == idx:
            return None
        return ProposedActionOut(command="jump_to_step", step_index=target)
    if action.command == "start_timer":
        seconds = intent.duration_seconds(query) or current.suggested_timer_seconds
        if seconds is None or not (1 <= seconds <= MAX_TIMER_SECONDS):
            return None
        label = current.suggested_timer_label or "Timer"
        return ProposedActionOut(
            command="start_timer", timer=ProposedTimer(label=label, duration_seconds=seconds)
        )
    return None
