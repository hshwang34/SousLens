"""Live pantry scan basket (brief 016, DECISIONS #28). Owner only.

* The model reports items through ``add_item``; every name is untrusted data and goes through
  the same candidate post-processing as photo/voice scans (``finalize_candidate``: dictionary
  normaliser, model-claim stripping, pantry duplicate lookup). One matcher, no fork.
* The basket holds one row per normalised key per scan (unique ``(scan_id, key)``), so repeats
  and concurrent duplicate posts never add a row. A repeat may raise the stored confidence.
* ``finish`` is the only pantry write: new, high-confidence, dictionary-recognised items go
  through ``service.create_items`` with the internal source ``live``; everything else is
  returned for review. Demo scans auto-save nothing. The finish answer is stored and replayed
  on a retry, so a lost response never hides what was auto-added.
* Scans expire 24 h after creation (``OBSERVATION_TTL``), are purged opportunistically on
  create, and an expired scan is the same 404 as a missing one.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta

from sqlalchemy import delete, func, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.providers.base import PantryCandidate
from app.core.errors import NotFound, RateLimited, StateConflict, ValidationError
from app.db.models import PantryLiveScan, PantryLiveScanItem, User
from app.domains.matching.dictionary import IngredientDictionary
from app.domains.matching.normalize import normalize
from app.domains.ownership import get_owned_or_404
from app.domains.pantry import service
from app.domains.pantry.observations import (
    OBSERVATION_TTL,
    RATE_LIMIT_PER_HOUR,
    _pantry_keys,
    finalize_candidate,
)
from app.domains.pantry.schemas import (
    MAX_ITEMS_PER_REQUEST,
    CreateLivePantryItems,
    LiveConfidence,
    LiveItemIn,
    LiveItemOut,
    LiveNewItem,
    LiveReviewItem,
    LiveScanFinished,
    LiveScanOut,
    PantryItemOut,
)

# Representative values inside the observation bins (high > 0.85, medium >= 0.6).
CONFIDENCE_VALUE: dict[str, float] = {"high": 0.9, "medium": 0.7, "low": 0.3}
_LOWER: dict[str, tuple[str, ...]] = {"high": ("medium", "low"), "medium": ("low",), "low": ()}
MAX_BASKET_ITEMS = MAX_ITEMS_PER_REQUEST


async def purge_expired_scans(session: AsyncSession, now: datetime) -> None:
    await session.execute(delete(PantryLiveScan).where(PantryLiveScan.expires_at <= now))


async def create_scan(
    session: AsyncSession, user: User, demo: bool, now: datetime
) -> PantryLiveScan:
    await service.lock_user(session, user.id, "live_scans")
    await purge_expired_scans(session, now)
    recent = await session.scalar(
        select(func.count())
        .select_from(PantryLiveScan)
        .where(
            PantryLiveScan.owner_user_id == user.id,
            PantryLiveScan.created_at > now - timedelta(hours=1),
        )
    )
    if (recent or 0) >= RATE_LIMIT_PER_HOUR:
        raise RateLimited("Too many pantry scans in the last hour; try again later")
    scan = PantryLiveScan(owner_user_id=user.id, demo=demo, expires_at=now + OBSERVATION_TTL)
    session.add(scan)
    await session.flush()
    await session.refresh(scan)
    return scan


async def _scan(
    session: AsyncSession,
    user: User,
    scan_id: uuid.UUID,
    now: datetime,
    *,
    lock: bool | dict[str, bool] | None = None,
    open_only: bool = False,
) -> PantryLiveScan:
    # Locked in the same query: a scan purged concurrently is the standard 404, never a 500.
    scan = await get_owned_or_404(
        session, PantryLiveScan, scan_id, user.id, label="Live scan", for_update=lock or False
    )
    if scan.expires_at <= now:
        raise NotFound("Live scan not found")
    if open_only and scan.status != "scanning":
        raise StateConflict("This scan is finished")
    return scan


def _out(row: PantryLiveScanItem, status: str, existing: uuid.UUID | None) -> LiveItemOut:
    return LiveItemOut(
        status=status,  # type: ignore[arg-type]
        key=row.key,
        canonical_name=row.key,
        display_name=row.display_name,
        confidence=row.confidence,  # type: ignore[arg-type]
        existing_pantry_item_id=existing,
    )


async def _repeat(
    session: AsyncSession, scan_id: uuid.UUID, key: str, confidence: LiveConfidence
) -> PantryLiveScanItem | None:
    """A repeat adds nothing; a more confident repeat upgrades the stored confidence."""
    if _LOWER[confidence]:
        await session.execute(
            update(PantryLiveScanItem)
            .where(
                PantryLiveScanItem.scan_id == scan_id,
                PantryLiveScanItem.key == key,
                PantryLiveScanItem.confidence.in_(_LOWER[confidence]),
            )
            .values(confidence=confidence)
            .execution_options(synchronize_session=False)
        )
    stmt = select(PantryLiveScanItem).where(
        PantryLiveScanItem.scan_id == scan_id, PantryLiveScanItem.key == key
    )
    return (
        await session.execute(stmt.execution_options(populate_existing=True))
    ).scalar_one_or_none()


async def add_item(
    session: AsyncSession,
    user: User,
    scan_id: uuid.UUID,
    body: LiveItemIn,
    dictionary: IngredientDictionary,
    now: datetime,
) -> LiveItemOut:
    scan = await _scan(session, user, scan_id, now, lock={"read": True}, open_only=True)
    pantry_keys = await _pantry_keys(session, user)
    cand = finalize_candidate(
        PantryCandidate(
            raw_label=body.name,
            canonical_name=body.name,
            confidence=CONFIDENCE_VALUE[body.confidence],
            evidence=body.evidence or "",
        ),
        "transcript",
        dictionary,
        pantry_keys,
    )
    if cand.canonical_name is None:
        raise ValidationError("name must name an ingredient", extra={"fields": ["name"]})
    key = cand.canonical_name
    in_dictionary = normalize(body.name, dictionary).entry is not None

    existing = await _repeat(session, scan.id, key, body.confidence)
    if existing is not None:
        return _out(existing, "already_in_basket", pantry_keys.get(key))
    count = await session.scalar(select(func.count()).where(PantryLiveScanItem.scan_id == scan.id))
    if (count or 0) >= MAX_BASKET_ITEMS:
        raise StateConflict("The basket is full; finish this scan and start another")
    inserted = await session.scalar(
        insert(PantryLiveScanItem)
        .values(
            scan_id=scan.id,
            key=key,
            display_name=cand.raw_label[:120],
            kind=body.kind,
            confidence=body.confidence,
            in_dictionary=in_dictionary,
            evidence=cand.evidence or None,
        )
        .on_conflict_do_nothing(index_elements=["scan_id", "key"])
        .returning(PantryLiveScanItem.id)
    )
    row = await _repeat(session, scan.id, key, body.confidence)
    assert row is not None
    if inserted is None:  # a concurrent duplicate post won the insert
        return _out(row, "already_in_basket", pantry_keys.get(key))
    duplicate_of = cand.duplicate_of
    return _out(row, "in_pantry" if duplicate_of else "new", duplicate_of)


async def remove_item(
    session: AsyncSession, user: User, scan_id: uuid.UUID, key: str, now: datetime
) -> None:
    scan = await _scan(session, user, scan_id, now, lock={"read": True}, open_only=True)
    removed = await session.scalar(
        delete(PantryLiveScanItem)
        .where(PantryLiveScanItem.scan_id == scan.id, PantryLiveScanItem.key == key)
        .returning(PantryLiveScanItem.id)
    )
    if removed is None:
        raise NotFound("Basket item not found")


async def _basket(
    session: AsyncSession, user: User, scan: PantryLiveScan
) -> list[tuple[PantryLiveScanItem, uuid.UUID | None]]:
    pantry_keys = await _pantry_keys(session, user)
    rows = (
        await session.execute(
            select(PantryLiveScanItem)
            .where(PantryLiveScanItem.scan_id == scan.id)
            .order_by(PantryLiveScanItem.created_at, PantryLiveScanItem.id)
        )
    ).scalars()
    return [(row, pantry_keys.get(row.key)) for row in rows]


async def get_scan(
    session: AsyncSession, user: User, scan_id: uuid.UUID, now: datetime
) -> LiveScanOut:
    scan = await _scan(session, user, scan_id, now)
    items = [
        _out(row, "in_pantry" if existing else "new", existing)
        for row, existing in await _basket(session, user, scan)
    ]
    return LiveScanOut(
        id=scan.id,
        demo=scan.demo,
        status=scan.status,  # type: ignore[arg-type]
        expires_at=scan.expires_at,
        items=items,
    )


async def finish(
    session: AsyncSession,
    user: User,
    scan_id: uuid.UUID,
    dictionary: IngredientDictionary,
    now: datetime,
) -> LiveScanFinished:
    scan = await _scan(session, user, scan_id, now, lock=True)
    if scan.finish_json is not None:  # a retried finish replays the first answer
        return LiveScanFinished.model_validate(scan.finish_json)
    await service.lock_user(session, user.id, "pantry")  # pantry keys can't change under us

    to_save: list[PantryLiveScanItem] = []
    review: list[LiveReviewItem] = []
    for row, existing in await _basket(session, user, scan):
        # Auto-save only a new, non-demo, high-confidence name the dictionary recognised.
        if existing is not None:
            reason = "in_pantry"
        elif scan.demo:
            reason = "demo"
        elif not row.in_dictionary:
            reason = "unrecognized"
        elif row.confidence != "high":
            reason = "unsure"
        else:
            to_save.append(row)
            continue
        out = _out(row, "in_pantry" if existing else "new", existing)
        review.append(LiveReviewItem(**out.model_dump(), reason=reason))  # type: ignore[arg-type]

    saved = []
    if to_save:
        body = CreateLivePantryItems(
            items=[
                LiveNewItem(
                    raw_label=r.display_name, source="live", confidence=CONFIDENCE_VALUE["high"]
                )
                for r in to_save
            ]
        )
        saved = await service.create_items(session, user, body, dictionary, now)
    result = LiveScanFinished(saved=[PantryItemOut.of(r) for r in saved], review=review)
    scan.status = "finished"
    scan.finished_at = now
    scan.finish_json = result.model_dump(mode="json")
    await session.flush()
    return result
