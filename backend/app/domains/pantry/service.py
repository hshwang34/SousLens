"""Pantry CRUD (PAN-01, PAN-04, PAN-05). Owner only: a foreign id is the same 404 as a missing one.

Pantry rows are written only by an explicit user action (POST with the items the user selected,
PATCH, confirm). Duplicates are never resolved silently: a new item whose normalised name matches
an existing item needs a ``resolution`` (``merge_into`` or ``keep_both``), otherwise the whole
request is rejected with 409 ``DUPLICATE_PANTRY_ITEM`` before anything is written.
"""

from __future__ import annotations

import uuid
from collections import defaultdict
from datetime import datetime
from decimal import Decimal

from sqlalchemy import delete, func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import DuplicatePantryItem, NotFound, StateConflict, ValidationError
from app.db.models import (
    ObservationStatus,
    PantryItem,
    PantryObservation,
    PantrySource,
    User,
)
from app.domains.matching.dictionary import IngredientDictionary
from app.domains.matching.normalize import Normalized, normalize
from app.domains.ownership import get_owned_or_404
from app.domains.pantry.schemas import (
    Conflict,
    CreatePantryItems,
    KeepBoth,
    MergeInto,
    NewItem,
    PantryItemOut,
    PantryPatch,
)


async def lock_user(session: AsyncSession, user_id: uuid.UUID, scope: str) -> None:
    """Serialise one user's writes of one kind for the rest of the transaction."""
    await session.execute(
        text("SELECT pg_advisory_xact_lock(hashtextextended(:k, 0))"),
        {"k": f"{scope}:{user_id}"},
    )


def _normalized_or_422(label: str, dictionary: IngredientDictionary, field: str) -> Normalized:
    norm = normalize(label, dictionary)
    if not norm.key:
        raise ValidationError("raw_label must name an ingredient", extra={"fields": [field]})
    return norm


def _quantity(value: float | None) -> Decimal | None:
    return None if value is None else Decimal(str(round(value, 3)))


def _confidence(item: NewItem) -> float | None:
    return None if item.source == "manual" else item.confidence


async def purge_expired_observations(session: AsyncSession, now: datetime) -> None:
    """Opportunistic TTL purge (PRIV-01): every pantry read/write and every new scan runs it."""
    await session.execute(delete(PantryObservation).where(PantryObservation.expires_at <= now))


async def list_items(session: AsyncSession, user: User, now: datetime) -> list[PantryItem]:
    await purge_expired_observations(session, now)
    stmt = (
        select(PantryItem)
        .where(PantryItem.owner_user_id == user.id)
        .order_by(PantryItem.normalized_name, PantryItem.created_at, PantryItem.id)
    )
    return list((await session.execute(stmt)).scalars().all())


async def get_item(session: AsyncSession, user: User, item_id: uuid.UUID) -> PantryItem:
    return await get_owned_or_404(session, PantryItem, item_id, user.id, label="Pantry item")


async def _link_observation(
    session: AsyncSession, user: User, observation_id: uuid.UUID, now: datetime
) -> None:
    obs = await get_owned_or_404(
        session, PantryObservation, observation_id, user.id, label="Observation"
    )
    if obs.expires_at <= now or obs.status != ObservationStatus.PENDING:
        if obs.expires_at > now and obs.status == ObservationStatus.CONFIRMED:
            raise StateConflict("These items were already added")
        raise NotFound("Observation not found")  # expired, failed or still reserved
    obs.status = ObservationStatus.CONFIRMED


async def create_items(
    session: AsyncSession,
    user: User,
    body: CreatePantryItems,
    dictionary: IngredientDictionary,
    now: datetime,
) -> list[PantryItem]:
    await lock_user(session, user.id, "pantry")
    norms = [
        _normalized_or_422(item.raw_label, dictionary, f"items.{i}.raw_label")
        for i, item in enumerate(body.items)
    ]

    existing_by_key: dict[str, list[PantryItem]] = defaultdict(list)
    keys = {n.key for n in norms}
    rows = (
        await session.execute(
            select(PantryItem)
            .where(PantryItem.owner_user_id == user.id, PantryItem.normalized_name.in_(keys))
            .order_by(PantryItem.last_confirmed_at.desc().nulls_last(), PantryItem.id)
        )
    ).scalars()
    for row in rows:
        existing_by_key[row.normalized_name].append(row)

    conflicts: list[Conflict] = []
    first_index: dict[str, int] = {}
    merge_targets: dict[uuid.UUID, int] = {}
    for i, (item, norm) in enumerate(zip(body.items, norms, strict=True)):
        matches = existing_by_key.get(norm.key, [])
        if isinstance(item.resolution, MergeInto):
            if item.resolution.merge_into not in {m.id for m in matches}:
                raise ValidationError(
                    "merge_into must name an existing pantry item with the same name",
                    extra={"fields": [f"items.{i}.resolution.merge_into"]},
                )
            target = item.resolution.merge_into
            if target in merge_targets:
                raise ValidationError(
                    f"items.{i} and items.{merge_targets[target]} merge into the same item; "
                    "combine them first",
                    extra={"fields": [f"items.{i}.resolution.merge_into"]},
                )
            merge_targets[target] = i
        elif item.resolution is None:
            if matches:
                conflicts.append(Conflict(index=i, existing=PantryItemOut.of(matches[0])))
            elif norm.key in first_index:
                raise ValidationError(
                    f"items.{i} is the same ingredient as items.{first_index[norm.key]}; combine "
                    "them or send keep_both",
                    extra={"fields": [f"items.{i}.raw_label"]},
                )
        first_index.setdefault(norm.key, i)
    if conflicts:
        raise DuplicatePantryItem(
            "Some items are already in your pantry; choose merge or keep both for each",
            extra={"details": {"conflicts": [c.model_dump(mode="json") for c in conflicts]}},
        )

    if body.observation_id is not None:
        await _link_observation(session, user, body.observation_id, now)
    await purge_expired_observations(session, now)

    by_id = {m.id: m for group in existing_by_key.values() for m in group}
    out: list[PantryItem] = []
    for item, norm in zip(body.items, norms, strict=True):
        if isinstance(item.resolution, MergeInto):
            row = by_id[item.resolution.merge_into]
            if item.quantity is not None:
                # Provenance travels with the amount it describes: a new amount brings its own
                # source/confidence/estimate flag; no new amount keeps all of the old ones.
                row.quantity = _quantity(item.quantity)
                row.unit = item.unit
                row.quantity_is_estimate = item.quantity_is_estimate
                row.source = PantrySource(item.source)
                row.confidence = _confidence(item)
                # The new amount's provenance replaces the old one entirely, including the link
                # to the scan it came from (None for a typed amount).
                row.source_observation_id = body.observation_id
            if item.storage_location is not None:
                row.storage_location = item.storage_location
            if item.note is not None:
                row.note = item.note
            row.last_confirmed_at = now
        else:
            assert item.resolution is None or isinstance(item.resolution, KeepBoth)
            row = PantryItem(
                owner_user_id=user.id,
                ingredient_id=norm.ingredient_id,
                raw_label=item.raw_label,
                normalized_name=norm.key,
                quantity=_quantity(item.quantity),
                unit=item.unit if item.quantity is not None else None,
                quantity_is_estimate=item.quantity_is_estimate,
                storage_location=item.storage_location,
                note=item.note,
                source=PantrySource(item.source),
                confidence=_confidence(item),
                source_observation_id=body.observation_id,
                last_confirmed_at=now,
            )
            session.add(row)
        out.append(row)
    await session.flush()
    for row in out:
        await session.refresh(row)
    return out


async def patch_item(
    session: AsyncSession,
    user: User,
    item_id: uuid.UUID,
    patch: PantryPatch,
    dictionary: IngredientDictionary,
    now: datetime,
) -> PantryItem:
    row = await get_item(session, user, item_id)
    fields = patch.model_fields_set
    if "raw_label" in fields and patch.raw_label is not None:
        norm = _normalized_or_422(patch.raw_label, dictionary, "raw_label")
        row.raw_label = patch.raw_label
        row.normalized_name = norm.key
        row.ingredient_id = norm.ingredient_id
    if "quantity" in fields:
        row.quantity = _quantity(patch.quantity)
        row.quantity_is_estimate = False  # the user typed it: no longer a photo estimate
        if patch.quantity is None:
            row.unit = None
    if "unit" in fields:
        row.unit = patch.unit if row.quantity is not None else None
    if "storage_location" in fields:
        row.storage_location = patch.storage_location
    if "note" in fields:
        row.note = patch.note
    row.last_confirmed_at = now
    row.updated_at = func.now()
    await session.flush()
    await session.refresh(row)
    return row


async def confirm_item(
    session: AsyncSession, user: User, item_id: uuid.UUID, now: datetime
) -> PantryItem:
    row = await get_item(session, user, item_id)
    row.last_confirmed_at = now
    row.updated_at = func.now()
    await session.flush()
    await session.refresh(row)
    return row


async def delete_item(session: AsyncSession, user: User, item_id: uuid.UUID) -> None:
    row = await get_item(session, user, item_id)
    await session.delete(row)
    await session.flush()
