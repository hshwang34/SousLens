"""Pantry observations: candidates only, never pantry truth (PAN-02, PAN-03, PRD §8.3, §10.2).

* The provider's output is re-validated against its Pydantic schema; malformed output is retried
  once, then surfaces as 502 ``AI_OUTPUT_INVALID`` (never a fabricated list).
* Candidates are post-processed here, whatever the provider: canonical names go through the
  shared dictionary normaliser, units outside the contract list become "amount unknown",
  photo quantities are always marked as estimates, confidence is binned (PRD §8.3 UX bins, not
  calibrated), unknown-bin candidates default to ``ignore``, and likely duplicates of the user's
  confirmed pantry are pre-flagged.
* Only the candidate JSON is stored, with a 24 h TTL; the image never reaches this module's
  storage (it lives in ``PantryObservationRequest.image_bytes`` for the provider call only).
* Expired rows are purged opportunistically on every new observation; 30 observations per user
  per hour, then 429.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta

import pydantic
from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.providers.base import (
    PantryCandidate,
    PantryExtractor,
    PantryObservation,
    PantryObservationRequest,
)
from app.core.errors import ProviderOutputInvalid, RateLimited
from app.db.models import ObservationMode, ObservationStatus, PantryItem, User
from app.db.models import PantryObservation as ObservationRow
from app.domains.matching.dictionary import IngredientDictionary
from app.domains.matching.normalize import normalize
from app.domains.matching.units import pantry_unit
from app.domains.pantry.schemas import CandidateOut, ConfidenceBin, ObservationOut
from app.domains.pantry.service import lock_user

OBSERVATION_TTL = timedelta(hours=24)
RATE_LIMIT_PER_HOUR = 30
HIGH_ABOVE = 0.85
MEDIUM_FROM = 0.6


def confidence_bin(confidence: float) -> ConfidenceBin:
    if confidence > HIGH_ABOVE:
        return "high"
    if confidence >= MEDIUM_FROM:
        return "medium"
    return "unknown"


def finalize_candidate(
    candidate: PantryCandidate,
    mode: str,
    dictionary: IngredientDictionary,
    pantry_keys: dict[str, uuid.UUID],
) -> CandidateOut:
    canonical: str | None = None
    if candidate.canonical_name:
        canonical = normalize(candidate.canonical_name, dictionary).key or None

    quantity, unit = candidate.quantity, None
    if quantity is not None:
        unit = "count" if candidate.unit is None else pantry_unit(candidate.unit)
        if unit is None:  # "2 cans", "a bunch": not a contract unit, so the amount is unknown
            quantity = None

    binned = confidence_bin(candidate.confidence)
    action = "ignore" if binned == "unknown" or canonical is None else "add"
    label_key = normalize(candidate.raw_label, dictionary).key
    duplicate_of = (pantry_keys.get(canonical) if canonical else None) or pantry_keys.get(label_key)
    return CandidateOut(
        raw_label=candidate.raw_label,
        canonical_name=canonical,
        quantity=quantity,
        unit=unit,
        quantity_is_estimate=mode == "photo" and quantity is not None,
        confidence=candidate.confidence,
        confidence_bin=binned,
        evidence=candidate.evidence,
        action=action,
        duplicate_of=duplicate_of,
    )


def unknowns_for(observation: PantryObservation, candidates: list[CandidateOut]) -> list[str]:
    if observation.unknowns:
        return list(observation.unknowns)
    return [f"{c.raw_label}: {c.evidence}" for c in candidates if c.canonical_name is None]


async def _observe_validated(
    provider: PantryExtractor, request: PantryObservationRequest
) -> PantryObservation:
    for attempt in (1, 2):
        try:
            result = await provider.observe(request)
            return PantryObservation.model_validate(
                result.model_dump() if isinstance(result, pydantic.BaseModel) else result
            )
        except pydantic.ValidationError as exc:
            if attempt == 2:
                raise ProviderOutputInvalid(
                    "The pantry scan came back malformed; try again or add items by hand"
                ) from exc
    raise AssertionError("unreachable")  # pragma: no cover


async def _pantry_keys(session: AsyncSession, user: User) -> dict[str, uuid.UUID]:
    stmt = (
        select(PantryItem.normalized_name, PantryItem.id)
        .where(PantryItem.owner_user_id == user.id)
        .order_by(PantryItem.last_confirmed_at.asc().nulls_first(), PantryItem.id)
    )
    # Later rows overwrite earlier ones: the most recently confirmed item wins.
    return {name: item_id for name, item_id in (await session.execute(stmt)).all()}


async def purge_expired(session: AsyncSession, now: datetime) -> int:
    result = await session.execute(delete(ObservationRow).where(ObservationRow.expires_at <= now))
    return int(getattr(result, "rowcount", 0) or 0)


async def create_observation(
    session: AsyncSession,
    user: User,
    provider: PantryExtractor,
    provider_name: str,
    request: PantryObservationRequest,
    dictionary: IngredientDictionary,
    now: datetime,
) -> ObservationOut:
    await lock_user(session, user.id, "observations")
    await purge_expired(session, now)
    recent = await session.scalar(
        select(func.count())
        .select_from(ObservationRow)
        .where(
            ObservationRow.owner_user_id == user.id,
            ObservationRow.created_at > now - timedelta(hours=1),
        )
    )
    if (recent or 0) >= RATE_LIMIT_PER_HOUR:
        raise RateLimited("Too many pantry scans in the last hour; try again later")

    observation = await _observe_validated(provider, request)
    pantry_keys = await _pantry_keys(session, user)
    candidates = [
        finalize_candidate(c, request.mode, dictionary, pantry_keys) for c in observation.candidates
    ]
    unknowns = unknowns_for(observation, candidates)
    row = ObservationRow(
        owner_user_id=user.id,
        mode=ObservationMode(request.mode),
        provider=provider_name,
        candidate_json=[c.model_dump(mode="json") for c in candidates],
        unknowns_json=unknowns,
        status=ObservationStatus.PENDING,
        expires_at=now + OBSERVATION_TTL,
    )
    session.add(row)
    await session.flush()
    return ObservationOut(
        observation_id=row.id,
        mode=request.mode,
        provider=provider_name,
        candidates=candidates,
        unknowns=unknowns,
        expires_at=row.expires_at,
    )
