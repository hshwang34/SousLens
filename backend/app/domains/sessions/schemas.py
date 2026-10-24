"""Cooking-session DTOs (brief 005 contract: ``docs/product/briefs/005-api-contract.md``).

Write side is strict (unknown keys → 422) with the shared text hygiene; the read side mirrors
the contract exactly.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from functools import partial
from typing import Annotated, Any, Literal

from pydantic import (
    BaseModel,
    BeforeValidator,
    ConfigDict,
    Field,
    StringConstraints,
    model_validator,
)

from app.domains.recipes.draft_schemas import check_text
from app.domains.recipes.schemas import RecipeDetail
from app.domains.sessions.oracle import CommandType

MAX_TIMER_SECONDS = 24 * 3600
QUERY_MAX = 500
NOTE_TEXT_MAX = 1000


def _single(max_length: int, min_length: int = 1) -> Any:
    return Annotated[
        str,
        BeforeValidator(partial(check_text, multiline=False, trim=True)),
        StringConstraints(min_length=min_length, max_length=max_length),
    ]


def _multi(max_length: int) -> Any:
    return Annotated[
        str,
        BeforeValidator(partial(check_text, multiline=True, trim=True)),
        StringConstraints(min_length=1, max_length=max_length),
    ]


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


AdaptationSource = Literal["rule", "ai"]


class AdaptationIn(_Strict):
    """Either a served ``suggestion_id`` or an explicit swap ("Use my changes from last time")."""

    ingredient_ref: _single(64)  # type: ignore[valid-type]
    suggestion_id: uuid.UUID | None = None
    replacement: _single(200) | None = None  # type: ignore[valid-type]
    ratio_or_amount: _single(200) | None = None  # type: ignore[valid-type]
    source: AdaptationSource | None = None
    reason: _single(300) | None = None  # type: ignore[valid-type]

    @model_validator(mode="after")
    def _one_form(self) -> AdaptationIn:
        if self.suggestion_id is not None:
            if self.replacement is not None:
                raise ValueError("send either suggestion_id or replacement, not both")
        elif self.replacement is None or self.source is None:
            raise ValueError("an explicit adaptation needs replacement and source")
        return self


class SessionCreateIn(_Strict):
    recipe_version_id: uuid.UUID
    adaptations: list[AdaptationIn] = Field(default_factory=list, max_length=30)


class TimerIn(_Strict):
    label: _single(120)  # type: ignore[valid-type]
    duration_seconds: int = Field(ge=1, le=MAX_TIMER_SECONDS)


class OutcomeIn(_Strict):
    result: Literal["cooked", "partly", "didnt_work"]
    save_changes: bool = False


MetadataValue = Annotated[str, StringConstraints(max_length=200)] | int | float | bool | None


class CommandIn(_Strict):
    command: CommandType
    expected_revision: int = Field(ge=0)
    # Deliberately untyped: anything but the JSON literal ``true`` is a 422
    # CONFIRMATION_REQUIRED (not a generic validation error), checked with ``is True``.
    user_confirmed: Any = None
    client_source: Annotated[str, StringConstraints(pattern=r"^[a-z_]{1,32}$")] = "ios_button"
    metadata: dict[Annotated[str, StringConstraints(max_length=64)], MetadataValue] = Field(
        default_factory=dict, max_length=20
    )
    step_index: int | None = Field(default=None, ge=0)
    adaptation: AdaptationIn | None = None
    adaptation_id: uuid.UUID | None = None
    timer: TimerIn | None = None
    timer_id: uuid.UUID | None = None
    outcome: OutcomeIn | None = None


class NoteIn(_Strict):
    text: _multi(NOTE_TEXT_MAX)  # type: ignore[valid-type]


class AskIn(_Strict):
    query: _multi(QUERY_MAX)  # type: ignore[valid-type]
    grounded_revision: int | None = Field(default=None, ge=0)


# --------------------------------------------------------------------------- read side


class AdaptationOut(BaseModel):
    id: uuid.UUID
    ingredient_ref: str
    original: str
    replacement: str
    ratio_or_amount: str | None
    source: AdaptationSource
    label: Literal["Common swap", "AI suggested adaptation"]
    reason: str | None
    approved_at: datetime
    allergy_warning: str | None = None
    risks: list[str] = Field(default_factory=list)
    # Re-checked on every read: true when the swap now matches the user's allergy list
    # (allergies changed mid-session). Such swaps are never saved as a private variation.
    conflicts_with_allergies: bool = False


class SuggestedTimer(BaseModel):
    label: str
    duration_seconds: int


class SessionStepOut(BaseModel):
    step_id: str
    order: int
    instruction: str
    original_instruction: str
    adapted: bool
    adaptation_ids: list[uuid.UUID]
    suggested_timer: SuggestedTimer | None


class TimerOut(BaseModel):
    id: uuid.UUID
    step_index: int
    label: str
    target_at: datetime
    status: Literal["running", "done", "cancelled"]


class NoteOut(BaseModel):
    id: uuid.UUID
    text: str
    created_at: datetime


class OutcomeOut(BaseModel):
    result: Literal["cooked", "partly", "didnt_work"]
    saved_changes: bool


class PantrySnapshotItem(BaseModel):
    pantry_item_id: uuid.UUID
    normalized_name: str


SessionStatusOut = Literal["created", "active", "paused", "completed", "abandoned"]


class SessionOut(BaseModel):
    id: uuid.UUID
    recipe_version_id: uuid.UUID
    recipe_id: uuid.UUID
    status: SessionStatusOut
    step_index: int
    steps_count: int
    revision: int
    recipe: RecipeDetail
    adaptations: list[AdaptationOut]
    steps: list[SessionStepOut]
    timers: list[TimerOut]
    notes: list[NoteOut]
    outcome: OutcomeOut | None
    pantry_snapshot: list[PantrySnapshotItem]
    started_at: datetime | None
    ended_at: datetime | None
    updated_at: datetime


class SessionSummary(BaseModel):
    id: uuid.UUID
    recipe_version_id: uuid.UUID
    recipe_id: uuid.UUID
    title: str
    status: SessionStatusOut
    step_index: int
    steps_count: int
    updated_at: datetime


class SessionList(BaseModel):
    items: list[SessionSummary]


class GroundingOut(BaseModel):
    type: Literal["recipe_step", "ingredient", "creator_note", "adaptation"]
    id: str


class ProposedTimer(BaseModel):
    label: str
    duration_seconds: int


class ProposedActionOut(BaseModel):
    command: Literal["next", "back", "jump_to_step", "start_timer"]
    step_index: int | None = None
    timer: ProposedTimer | None = None


class AskOut(BaseModel):
    message_id: uuid.UUID
    answer_text: str
    grounding: list[GroundingOut]
    grounded_session_revision: int
    stale: bool
    uncertainty: Literal["low", "medium", "high"]
    safety_notice: str | None
    proposed_action: ProposedActionOut | None
    requires_confirmation: bool


class VariationAdaptation(AdaptationOut):
    """Exactly the Session adaptation shape (iOS reuses one decoder); ``id``/``approved_at``
    are those of the session adaptation that was saved."""


class VariationOut(BaseModel):
    adaptations: list[VariationAdaptation]
    saved_at: datetime
    recipe_version_id: uuid.UUID
