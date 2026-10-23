"""Pantry DTOs (brief 004 contract: ``docs/product/briefs/004-api-contract.md``).

Write side is strict (unknown keys → 422) and every text field goes through the shared
``check_text`` hygiene; read side mirrors the contract exactly.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from functools import partial
from typing import Annotated, Literal

from pydantic import (
    BaseModel,
    BeforeValidator,
    ConfigDict,
    Field,
    StringConstraints,
    field_validator,
    model_validator,
)

from app.db.models import PantryItem
from app.domains.matching.units import PantryUnit
from app.domains.recipes.draft_schemas import NOTE_MAX, check_text

LABEL_MAX = 200
TRANSCRIPT_MAX = 2000
MAX_ITEMS_PER_REQUEST = 100
QUANTITY_MAX = 1_000_000

StorageLocationIn = Literal["fridge", "freezer", "pantry", "counter", "other"]
SourceIn = Literal["manual", "voice", "photo"]
ConfidenceBin = Literal["high", "medium", "unknown"]

Label = Annotated[
    str,
    BeforeValidator(partial(check_text, multiline=False, trim=True)),
    StringConstraints(min_length=1, max_length=LABEL_MAX),
]
NoteText = Annotated[
    str,
    BeforeValidator(partial(check_text, multiline=True, trim=True)),
    StringConstraints(max_length=NOTE_MAX),
]
Transcript = Annotated[
    str,
    BeforeValidator(partial(check_text, multiline=True, trim=True)),
    StringConstraints(min_length=1, max_length=TRANSCRIPT_MAX),
]
Quantity = Annotated[float, Field(ge=0, le=QUANTITY_MAX, allow_inf_nan=False)]


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class PantryItemOut(BaseModel):
    id: uuid.UUID
    raw_label: str
    normalized_name: str
    ingredient_id: uuid.UUID | None
    quantity: float | None
    unit: str | None
    quantity_is_estimate: bool
    storage_location: str | None
    note: str | None
    source: SourceIn
    confidence: float | None
    last_confirmed_at: datetime | None
    created_at: datetime
    updated_at: datetime

    @classmethod
    def of(cls, row: PantryItem) -> PantryItemOut:
        return cls(
            id=row.id,
            raw_label=row.raw_label,
            normalized_name=row.normalized_name,
            ingredient_id=row.ingredient_id,
            quantity=float(row.quantity) if row.quantity is not None else None,
            unit=row.unit,
            quantity_is_estimate=row.quantity_is_estimate,
            storage_location=row.storage_location,
            note=row.note,
            source=row.source.value,  # type: ignore[arg-type]
            confidence=row.confidence,
            last_confirmed_at=row.last_confirmed_at,
            created_at=row.created_at,
            updated_at=row.updated_at,
        )


class PantryList(BaseModel):
    items: list[PantryItemOut]


class MergeInto(_Strict):
    merge_into: uuid.UUID


class KeepBoth(_Strict):
    keep_both: Literal[True]


class NewItem(_Strict):
    raw_label: Label
    quantity: Quantity | None = None
    unit: PantryUnit | None = None
    storage_location: StorageLocationIn | None = None
    note: NoteText | None = None
    source: SourceIn
    confidence: float | None = Field(default=None, ge=0, le=1)
    quantity_is_estimate: bool = False
    resolution: MergeInto | KeepBoth | None = None

    @model_validator(mode="after")
    def _estimate_only_for_photo_counts(self) -> NewItem:
        # Contract: true only when the quantity came from a photo count (PRD §8.3).
        if self.quantity_is_estimate and (self.source != "photo" or self.quantity is None):
            raise ValueError("quantity_is_estimate is only allowed for a photo quantity")
        return self


class CreatePantryItems(_Strict):
    items: list[NewItem] = Field(min_length=1, max_length=MAX_ITEMS_PER_REQUEST)
    observation_id: uuid.UUID | None = None


class PantryPatch(_Strict):
    """Only the fields present are applied; ``raw_label`` may not be null."""

    raw_label: Label | None = None
    quantity: Quantity | None = None
    unit: PantryUnit | None = None
    storage_location: StorageLocationIn | None = None
    note: NoteText | None = None

    @field_validator("raw_label")
    @classmethod
    def _label_not_null(cls, value: str | None) -> str:
        if value is None:
            raise ValueError("raw_label cannot be null")
        return value


class ConfirmBody(_Strict):
    pass


class Conflict(BaseModel):
    index: int
    existing: PantryItemOut


# --- observations -------------------------------------------------------------------------


class TranscriptObservationIn(_Strict):
    mode: Literal["transcript"]
    transcript: Transcript


class CandidateOut(BaseModel):
    raw_label: str
    canonical_name: str | None
    quantity: float | None
    unit: str | None
    quantity_is_estimate: bool
    confidence: float
    confidence_bin: ConfidenceBin
    evidence: str
    action: Literal["add", "ignore"]
    duplicate_of: uuid.UUID | None


class ObservationOut(BaseModel):
    observation_id: uuid.UUID
    mode: Literal["transcript", "photo"]
    provider: str
    candidates: list[CandidateOut]
    unknowns: list[str]
    requires_confirmation: Literal[True] = True
    expires_at: datetime
