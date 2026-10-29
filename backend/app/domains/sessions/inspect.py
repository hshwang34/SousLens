"""``POST /sessions/{id}/inspect``: one deliberate photo for the current step (PRD §8.1.6, §11.2,
brief 007).

* The photo is read into memory, sent to the visual observer for this one call and dropped. It
  is never written to disk, the database or a log (PRD §13.2). Only the question and the text
  observation are kept, as session turns, so the coach has the context afterwards.
* The answer is always an **AI observation** with a confidence bin, ``food_safety_certified``
  is always false, and ``recommended_step_change`` is always null: a photo never moves a step.
* DECISIONS #15 applies exactly as for ``/ask``: a doneness / safe-to-eat / temperature /
  raw-tasting question gets the fixed template and the model is not called; every model
  observation is post-filtered (certifying sentences dropped, the thermometer notice attached),
  and for high-risk foods the notice is always attached.
* Limits: 20 photos per user per hour (``usage_events``), reserved and committed before the
  provider call so no lock spans it. The Gemini budget is enforced by the guarded provider.
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from datetime import UTC, datetime, timedelta

import pydantic
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.providers.base import InspectRequest, InspectResponse, StepSummary, VisualObserver
from app.core.errors import (
    AppError,
    InvalidTransition,
    NotFound,
    ProviderOutputInvalid,
    ProviderUnavailable,
)
from app.db.models import CookingSession, MessageRole, SessionMessage, User
from app.domains import usage
from app.domains.safety.content import (
    CANT_TELL,
    DONENESS_NOTICE,
    RAW_TASTING_NOTICE,
    is_doneness_question,
    is_high_risk,
    is_raw_tasting_request,
    is_temperature_question,
    mentions_safety_terms,
    strip_model_claims,
    temperature_table,
)
from app.domains.sessions import service
from app.domains.sessions.ask import _summary, doneness_notice_for
from app.domains.sessions.schemas import GroundingOut, InspectOut
from app.domains.substitutions.service import context_from

log = logging.getLogger("souslens.sessions.inspect")

INSPECT = "inspect"
USER_INSPECTS_PER_HOUR = 20
PROVIDER_TIMEOUT_SECONDS = 20.0
PHOTO_LIMIT = (
    "One photo can't show everything in the pan, and it can't confirm doneness or food safety."
)


async def _observe(provider: VisualObserver, request: InspectRequest) -> InspectResponse:
    for attempt in (1, 2):
        try:
            result = await asyncio.wait_for(
                provider.inspect(request), timeout=PROVIDER_TIMEOUT_SECONDS
            )
            return InspectResponse.model_validate(
                result.model_dump(warnings=False)
                if isinstance(result, pydantic.BaseModel)
                else result
            )
        except pydantic.ValidationError as exc:
            if attempt == 2:
                raise ProviderOutputInvalid(
                    "The photo check came back malformed; the step text is unchanged"
                ) from exc
        except AppError:
            raise
        except Exception as exc:
            log.warning("visual observer failed", extra={"error_type": type(exc).__name__})
            raise ProviderUnavailable(
                "The photo check is unavailable; the current step is shown as written"
            ) from exc
    raise AssertionError("unreachable")  # pragma: no cover


def _said(step: StepSummary) -> str:
    cues = "; ".join(step.success_cues) if step.success_cues else step.instruction
    return f"The recipe says (step {step.order + 1}): {cues.rstrip('.')}."


def _template(step: StepSummary, notice: str, *, refusal: bool) -> dict:
    """The fixed answer for a safety question about a photo: no model prose at all."""
    return {
        "observation": notice if refusal else CANT_TELL,
        "step_alignment": _said(step),
        "confidence": "low",
        "limitations": [PHOTO_LIMIT],
        "suggested_action": None if refusal else notice,
        "safety_notice": notice,
    }


def _postprocess(
    response: InspectResponse, query: str, step: StepSummary, context: list[str]
) -> dict:
    high_risk = is_high_risk(context)
    dropped = 0

    def clean(text: str | None) -> str | None:
        nonlocal dropped
        if text is None:
            return None
        kept, n = strip_model_claims(text, high_risk=high_risk)
        dropped += n
        return kept or None

    observation = clean(response.observation)
    alignment = clean(response.step_alignment) or _said(step)
    suggested = clean(response.suggested_action)
    limitations = [t for t in (clean(x) for x in response.limitations) if t]
    if PHOTO_LIMIT not in limitations:
        limitations.append(PHOTO_LIMIT)
    texts = [response.observation, response.step_alignment, response.suggested_action or ""]
    touched = mentions_safety_terms(query) or any(mentions_safety_terms(t) for t in texts)
    notice = doneness_notice_for(query, context)
    if not observation:
        return _template(step, notice, refusal=False)
    confidence = response.confidence
    safety_notice = None
    if touched or dropped:
        safety_notice = notice
        confidence = "low"
    elif high_risk:
        safety_notice = DONENESS_NOTICE  # DECISIONS #15: high-risk foods always carry it
    return {
        "observation": observation,
        "step_alignment": alignment,
        "confidence": confidence,
        "limitations": limitations,
        "suggested_action": suggested,
        "safety_notice": safety_notice,
    }


async def inspect(
    session: AsyncSession,
    user: User,
    session_id: uuid.UUID,
    *,
    query: str,
    grounded_revision: int | None,
    captured_at: str | None,
    image: bytes,
    mime_type: str,
    provider: VisualObserver,
) -> InspectOut:
    now = datetime.now(UTC)
    row = await service._owned(session, user, session_id, lock=True)
    if row.status.value in ("completed", "abandoned"):
        raise InvalidTransition(f"session is {row.status.value}; photo checks are closed")
    await usage.reserve(
        session,
        user.id,
        INSPECT,
        limit=USER_INSPECTS_PER_HOUR,
        window=timedelta(hours=1),
        now=now,
        message="Too many photo checks in the last hour; try again later",
    )
    version, recipe = await service._pinned(session, row)
    ctx = context_from(version, recipe)
    overlay = (row.adaptation_json or {}).get("steps", {})
    idx = min(row.step_index, max(len(ctx.steps) - 1, 0))
    raw_step = ctx.steps[idx]
    entry = overlay.get(raw_step.id)
    step = _summary(raw_step, entry["instruction"] if entry else None)
    names = [i.name for i in ctx.ingredients]
    revision = row.revision

    session.add(
        SessionMessage(
            session_id=row.id,
            role=MessageRole.USER,
            text=query,
            grounded_step_index=idx,
            grounded_revision=revision,
            source_refs_json=[],
            created_at=now,
        )
    )
    await session.commit()  # the rate-limit slot sticks even if the provider fails

    raw_context = [*(s.instruction for s in ctx.steps[: idx + 1]), *raw_step.warnings, *names]
    context = [step.instruction, *step.warnings, *names]
    if is_raw_tasting_request(query, raw_context):
        out = _template(step, RAW_TASTING_NOTICE, refusal=True)
    elif is_temperature_question(query):
        out = _template(
            step, f"{DONENESS_NOTICE} {temperature_table(query, context)}", refusal=True
        )
    elif is_doneness_question(query, context):
        out = _template(step, doneness_notice_for(query, context), refusal=False)
    else:
        request = InspectRequest(
            session_id=str(row.id),
            grounded_revision=revision,
            query=query,
            image_ref="inline",
            mime_type=mime_type,
            captured_at=captured_at,
            current_step=step,
            image_bytes=image,
            recipe_title=ctx.title,
            ingredient_names=names,
        )
        try:
            response = await _observe(provider, request)
        finally:
            request.image_bytes = None  # drop our reference to the photo straight away
        out = _postprocess(response, query, step, context)

    current_revision = await session.scalar(
        select(CookingSession.revision).where(CookingSession.id == row.id)
    )
    if current_revision is None:
        raise NotFound("Session not found")
    stale = (grounded_revision is not None and grounded_revision != revision) or (
        current_revision != revision
    )
    grounding = [GroundingOut(type="recipe_step", id=step.id)]
    reply = SessionMessage(
        session_id=row.id,
        role=MessageRole.ASSISTANT,
        text=f"(AI observation) {out['observation']}",
        grounded_step_index=idx,
        grounded_revision=revision,
        source_refs_json=[g.model_dump() for g in grounding],
        created_at=datetime.now(UTC),
    )
    session.add(reply)
    try:
        await session.flush()
    except IntegrityError as exc:
        raise NotFound("Session not found") from exc
    return InspectOut(
        observation_id=reply.id,
        grounded_revision=revision,
        stale=stale,
        grounding=grounding,
        food_safety_certified=False,
        recommended_step_change=None,
        **out,
    )
