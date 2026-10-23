"""``POST /sessions/{id}/ask`` (COOK-03/04, PRD §8.5, Appendix A, brief 005 contract).

* The grounding packet holds only what §8.5 allows: the pinned version's title, servings and
  original ingredient amounts, the current step ± 1, creator notes and warnings, approved
  adaptations, the session's relevant pantry subset, the last 10 turns, running timers and the
  caller's food preferences.
* Recipe text, notes and the query are untrusted data. The coach never changes state; its
  ``proposed_action`` is kept only when the user's own query asked for it and it is legal right
  now, and it always ``requires_confirmation``.
* Deterministic safety wins over the coach: a doneness / safety question always carries the
  thermometer notice and never a certification; tasting anything raw is refused.
* Rate limit: 60 asks per session per hour (the user turn is the slot, reserved and committed
  before the provider call so the lock never spans it).
"""

from __future__ import annotations

import asyncio
import logging
import re
import uuid
from datetime import UTC, datetime, timedelta

import pydantic
from sqlalchemy import func, select
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
    ProviderOutputInvalid,
    ProviderUnavailable,
    RateLimited,
)
from app.db.models import CookingSession, MessageRole, SessionMessage, User
from app.domains.recipes.schemas import IngredientOut, StepOut
from app.domains.safety.content import (
    RAW_TASTING_NOTICE,
    doneness_notice,
    is_raw_tasting_request,
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

RATE_LIMIT_PER_HOUR = 60
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
_CERTIFY_RE = re.compile(
    r"[^.!?]*\b(is|are|it'?s|they'?re|looks?|seems?)\s+(fully\s+)?"
    r"(done|safe(\s+to\s+eat)?|cooked\s+through|ready\s+to\s+eat)\b[^.!?]*[.!?]?",
    re.IGNORECASE,
)


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

    response = await _coach(provider, packet)

    out = _postprocess(response, body, packet, ctx.steps, names, idx, adaptations)
    current_revision = await session.scalar(
        select(CookingSession.revision).where(CookingSession.id == row.id)
    )
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
    await session.flush()
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
    proposed = _gate_action(response, body.query, len(steps), idx)

    context = [current.instruction, *current.warnings, *names.values()]
    if is_raw_tasting_request(body.query, context):
        answer = (
            f"My suggestion: {RAW_TASTING_NOTICE} The recipe says (step {current.order + 1}): "
            f"{current.instruction}"
        )
        safety_notice = RAW_TASTING_NOTICE
        proposed = None
    elif notice := doneness_notice(body.query, context):
        # Never a certification, whatever the model said.
        answer = _CERTIFY_RE.sub("", answer).strip() or (
            f"The recipe says (step {current.order + 1}): {current.instruction}"
        )
        safety_notice = notice
        uncertainty = "high" if uncertainty == "high" else "medium"
        proposed = None

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
    return {
        "answer_text": answer,
        "grounding": grounding,
        "uncertainty": uncertainty,
        "safety_notice": safety_notice,
        "proposed_action": proposed,
        "requires_confirmation": proposed is not None,
    }


def _gate_action(
    response: CoachResponse, query: str, steps_count: int, idx: int
) -> ProposedActionOut | None:
    action = response.proposed_action
    if action is None or action.command not in intent.intents(query):
        return None  # only what the user asked for; recipe text can never propose
    last = max(steps_count - 1, 0)
    if action.command == "next":
        return ProposedActionOut(command="next") if idx < last else None
    if action.command == "back":
        return ProposedActionOut(command="back") if idx > 0 else None
    if action.command == "jump_to_step":
        target = action.step_index
        if target is None or not (0 <= target <= last) or target == idx:
            return None
        return ProposedActionOut(command="jump_to_step", step_index=target)
    if action.command == "start_timer":
        seconds = action.timer_seconds
        if seconds is None or not (1 <= seconds <= MAX_TIMER_SECONDS):
            return None
        label = (action.timer_label or "Timer").strip()[:120] or "Timer"
        return ProposedActionOut(
            command="start_timer", timer=ProposedTimer(label=label, duration_seconds=seconds)
        )
    return None
