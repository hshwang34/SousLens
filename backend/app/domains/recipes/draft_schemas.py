"""Creator draft DTOs (brief 003 contract): the editable Draft, its summary, publish rules.

Write side is strict (unknown keys rejected, limits enforced) so a client typo never silently
lands in ``structured_draft_json``; the read side (``DraftContent``) is tolerant so an older or
additive stored draft can always be rendered.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any, Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.domains.recipes.schemas import EvidenceOrigin, IngredientOut, StepOut

DraftStatusOut = Literal["draft", "published"]

TITLE_MAX = 120
MAX_INGREDIENTS = 200
MAX_STEPS = 100
MAX_LIST_ITEMS = 50
MAX_TAGS = 20

_SHORT = 200
_TEXT = 2000
_ID = 64
URL_MAX = 2048


def validate_https_url(value: str | None) -> str | None:
    """Accept only an absolute ``https://`` URL with a host, no credentials, ≤ 2048 chars.

    Until uploads land (Slice 5, media ids served through signed URLs) a cover image is just
    an external link the creator pastes; this keeps ``javascript:``, ``file:``, relative
    paths and ``user:pass@host`` out of the stored recipe metadata.
    """
    if value is None:
        return None
    value = value.strip()
    if len(value) > URL_MAX:
        raise ValueError(f"must be at most {URL_MAX} characters")
    parts = urlsplit(value)
    if parts.scheme.lower() != "https" or not parts.hostname:
        raise ValueError("must be an absolute https:// URL")
    if parts.username is not None or parts.password is not None:
        raise ValueError("must not contain credentials")
    return value


class DraftIngredientIn(BaseModel):
    """Same shape as ``RecipeDetail.ingredients``; ``name`` may be blank while drafting."""

    model_config = ConfigDict(extra="forbid")

    id: str = Field(min_length=1, max_length=_ID)
    name: str = Field(default="", max_length=_SHORT)
    quantity: float | None = Field(default=None, ge=0)
    unit: str | None = Field(default=None, max_length=32)
    optional: bool = False
    preparation: str | None = Field(default=None, max_length=_SHORT)
    notes: str | None = Field(default=None, max_length=_TEXT)


class DraftStepIn(BaseModel):
    """Same shape as ``RecipeDetail.steps``. ``order`` is accepted but rewritten from the array
    position on save (arrays replace whole, so the array *is* the order)."""

    model_config = ConfigDict(extra="forbid")

    id: str = Field(min_length=1, max_length=_ID)
    order: int | None = Field(default=None, ge=0)
    instruction: str = Field(default="", max_length=_TEXT)
    ingredient_refs: list[str] = Field(default_factory=list, max_length=MAX_INGREDIENTS)
    estimated_minutes: int | None = Field(default=None, ge=0, le=24 * 60)
    success_cues: list[str] = Field(default_factory=list, max_length=MAX_LIST_ITEMS)
    warnings: list[str] = Field(default_factory=list, max_length=MAX_LIST_ITEMS)
    creator_note: str | None = Field(default=None, max_length=_TEXT)
    source_clip_id: str | None = Field(default=None, max_length=_ID)
    source_start_ms: int | None = Field(default=None, ge=0)
    source_end_ms: int | None = Field(default=None, ge=0)
    evidence_origin: EvidenceOrigin = "creator_authored"


class DraftPatch(BaseModel):
    """Partial update: only fields present in the request body are applied (``null`` clears a
    scalar). Arrays replace whole. Read-only Draft fields are accepted and ignored so a client
    may echo a whole Draft back; any other unknown key is rejected."""

    model_config = ConfigDict(extra="forbid")

    title: str | None = Field(default=None, max_length=1000)
    summary: str | None = Field(default=None, max_length=_TEXT)
    tags: list[str] = Field(default_factory=list, max_length=MAX_TAGS)
    cover_image_url: str | None = Field(default=None, max_length=URL_MAX)
    servings: int | None = Field(default=None, ge=0, le=1000)
    prep_minutes: int | None = Field(default=None, ge=0, le=7 * 24 * 60)
    cook_minutes: int | None = Field(default=None, ge=0, le=7 * 24 * 60)
    ingredients: list[DraftIngredientIn] = Field(default_factory=list, max_length=MAX_INGREDIENTS)
    steps: list[DraftStepIn] = Field(default_factory=list, max_length=MAX_STEPS)
    creator_notes: list[str] = Field(default_factory=list, max_length=MAX_LIST_ITEMS)
    dietary_warnings: list[str] = Field(default_factory=list, max_length=MAX_LIST_ITEMS)

    @field_validator("cover_image_url")
    @classmethod
    def _cover_is_https(cls, value: str | None) -> str | None:
        return validate_https_url(value)

    # Read-only Draft fields: tolerated so `PATCH` can receive a whole Draft, never applied.
    id: Any = Field(default=None, exclude=True)
    recipe_id: Any = Field(default=None, exclude=True)
    status: Any = Field(default=None, exclude=True)
    validation: Any = Field(default=None, exclude=True)
    created_at: Any = Field(default=None, exclude=True)
    updated_at: Any = Field(default=None, exclude=True)


CONTENT_FIELDS: frozenset[str] = frozenset(
    {
        "title",
        "summary",
        "tags",
        "cover_image_url",
        "servings",
        "prep_minutes",
        "cook_minutes",
        "ingredients",
        "steps",
        "creator_notes",
        "dietary_warnings",
    }
)


class DraftContent(BaseModel):
    """What ``recipe_drafts.structured_draft_json`` holds. Tolerant on read."""

    model_config = ConfigDict(extra="ignore")

    title: str | None = None
    summary: str | None = None
    tags: list[str] = Field(default_factory=list)
    cover_image_url: str | None = None
    servings: int | None = None
    prep_minutes: int | None = None
    cook_minutes: int | None = None
    ingredients: list[IngredientOut] = Field(default_factory=list)
    steps: list[StepOut] = Field(default_factory=list)
    creator_notes: list[str] = Field(default_factory=list)
    dietary_warnings: list[str] = Field(default_factory=list)


class DraftProblem(BaseModel):
    field: str
    message: str


class DraftValidation(BaseModel):
    publishable: bool
    problems: list[DraftProblem]


class DraftSummary(BaseModel):
    id: uuid.UUID
    recipe_id: uuid.UUID | None
    status: DraftStatusOut
    title: str | None
    summary: str | None
    tags: list[str]
    cover_image_url: str | None
    servings: int | None
    prep_minutes: int | None
    cook_minutes: int | None
    ingredient_count: int
    step_count: int
    validation: DraftValidation
    created_at: datetime
    updated_at: datetime


class Draft(BaseModel):
    id: uuid.UUID
    recipe_id: uuid.UUID | None
    status: DraftStatusOut
    title: str | None
    summary: str | None
    tags: list[str]
    cover_image_url: str | None
    servings: int | None
    prep_minutes: int | None
    cook_minutes: int | None
    ingredients: list[IngredientOut]
    steps: list[StepOut]
    creator_notes: list[str]
    dietary_warnings: list[str]
    validation: DraftValidation
    created_at: datetime
    updated_at: datetime


class DraftList(BaseModel):
    items: list[DraftSummary]


class PublishResult(BaseModel):
    recipe_id: uuid.UUID
    recipe_version_id: uuid.UUID
    version_number: int
    share_url: str
