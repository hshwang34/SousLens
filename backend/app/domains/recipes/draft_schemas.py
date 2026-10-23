"""Creator draft DTOs (brief 003 contract): the editable Draft, its summary, publish rules.

Write side is strict (unknown keys rejected, limits enforced) so a client typo never silently
lands in ``structured_draft_json``; the read side (``DraftContent``) is tolerant so an older or
additive stored draft can always be rendered.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from functools import partial
from typing import Annotated, Any, Literal
from urllib.parse import urlsplit

from pydantic import (
    BaseModel,
    BeforeValidator,
    ConfigDict,
    Field,
    StringConstraints,
    field_validator,
)

from app.domains.recipes.schemas import EvidenceOrigin, IngredientOut, StepOut

DraftStatusOut = Literal["draft", "published"]

TITLE_MAX = 120
MAX_INGREDIENTS = 200
MAX_STEPS = 100
MAX_LIST_ITEMS = 50
MAX_TAGS = 20

# Per-field text limits (fix round 1, item 4), counted after trimming where trimming applies.
TAG_MAX = 40
LIST_ITEM_MAX = 500  # creator_notes, dietary_warnings, success_cues, warnings
ID_MAX = 64  # ingredient/step ids, ingredient_refs, source_clip_id
NAME_MAX = 200
UNIT_MAX = 32
PREPARATION_MAX = 200
NOTE_MAX = 500  # ingredient notes, step creator_note
INSTRUCTION_MAX = 2000
SUMMARY_MAX = 1000
URL_MAX = 2048

# C0 controls except \t \n \r, DEL, and the bidi embedding/override/isolate controls that can
# visually reorder text ("Trojan Source"). Rejected in every text field, before any trimming.
_FORBIDDEN = frozenset(
    [chr(c) for c in range(0x00, 0x09)]
    + ["\x0b", "\x0c"]
    + [chr(c) for c in range(0x0E, 0x20)]
    + ["\x7f"]
    + [chr(c) for c in range(0x202A, 0x202F)]
    + [chr(c) for c in range(0x2066, 0x206A)]
)
_LINE_BREAKS = frozenset("\n\r")


def check_text(value: Any, *, multiline: bool, trim: bool = False, lower: bool = False) -> Any:
    """Shared text hygiene, run on the raw value before any length check.

    Rejects forbidden characters (and line breaks in single-line fields), then optionally trims
    and lowercases, so ``StringConstraints`` lengths count the *stored* value. Non-strings pass
    through so pydantic reports the type error normally.
    """
    if isinstance(value, str):
        if any(ch in _FORBIDDEN for ch in value):
            raise ValueError("contains a control or bidirectional-override character")
        if not multiline and any(ch in _LINE_BREAKS for ch in value):
            raise ValueError("must be a single line")
        if trim:
            value = value.strip()
        if lower:
            value = value.lower()
    return value


_SINGLE = BeforeValidator(partial(check_text, multiline=False))
_MULTI = BeforeValidator(partial(check_text, multiline=True))

Title = Annotated[
    str,
    BeforeValidator(partial(check_text, multiline=False, trim=True)),
    StringConstraints(max_length=TITLE_MAX),
]
Summary = Annotated[str, _MULTI, StringConstraints(max_length=SUMMARY_MAX)]
Tag = Annotated[
    str,
    BeforeValidator(partial(check_text, multiline=False, trim=True, lower=True)),
    StringConstraints(min_length=1, max_length=TAG_MAX),
]
ListItem = Annotated[str, _MULTI, StringConstraints(max_length=LIST_ITEM_MAX)]
ItemId = Annotated[str, _SINGLE, StringConstraints(min_length=1, max_length=ID_MAX)]
Ref = Annotated[str, _SINGLE, StringConstraints(max_length=ID_MAX)]
Name = Annotated[str, _SINGLE, StringConstraints(max_length=NAME_MAX)]
Unit = Annotated[str, _SINGLE, StringConstraints(max_length=UNIT_MAX)]
Preparation = Annotated[str, _SINGLE, StringConstraints(max_length=PREPARATION_MAX)]
Note = Annotated[str, _MULTI, StringConstraints(max_length=NOTE_MAX)]
Instruction = Annotated[str, _MULTI, StringConstraints(max_length=INSTRUCTION_MAX)]


def validate_https_url(value: str | None) -> str | None:
    """Accept only an absolute ``https://`` URL with a host, no credentials, ≤ 2048 chars.

    Until uploads land (Slice 5, media ids served through signed URLs) a cover image is just
    an external link the creator pastes; this keeps ``javascript:``, ``file:``, relative
    paths and ``user:pass@host`` out of the stored recipe metadata. The raw value must not
    contain whitespace/control characters (≤ U+0020), DEL or a backslash (URL parsers disagree
    on those); it is stored exactly as given once every check passes.
    """
    if value is None:
        return None
    if len(value) > URL_MAX:
        raise ValueError(f"must be at most {URL_MAX} characters")
    if any(ord(ch) <= 0x20 or ch in ("\x7f", "\\") for ch in value):
        raise ValueError("must not contain whitespace, control characters or backslashes")
    try:
        parts = urlsplit(value)
        _ = parts.port  # raises ValueError on a non-numeric or out-of-range port
    except ValueError as exc:
        raise ValueError("must be a valid absolute https:// URL") from exc
    if parts.scheme.lower() != "https" or not parts.hostname:
        raise ValueError("must be an absolute https:// URL")
    if parts.username is not None or parts.password is not None:
        raise ValueError("must not contain credentials")
    return value


class DraftIngredientIn(BaseModel):
    """Same shape as ``RecipeDetail.ingredients``; ``name`` may be blank while drafting."""

    model_config = ConfigDict(extra="forbid")

    id: ItemId
    name: Name = ""
    quantity: float | None = Field(default=None, ge=0)
    unit: Unit | None = None
    optional: bool = False
    preparation: Preparation | None = None
    notes: Note | None = None


class DraftStepIn(BaseModel):
    """Same shape as ``RecipeDetail.steps``. ``order`` is accepted but rewritten from the array
    position on save (arrays replace whole, so the array *is* the order)."""

    model_config = ConfigDict(extra="forbid")

    id: ItemId
    order: int | None = Field(default=None, ge=0)
    instruction: Instruction = ""
    ingredient_refs: list[Ref] = Field(default_factory=list, max_length=MAX_INGREDIENTS)
    estimated_minutes: int | None = Field(default=None, ge=0, le=24 * 60)
    success_cues: list[ListItem] = Field(default_factory=list, max_length=MAX_LIST_ITEMS)
    warnings: list[ListItem] = Field(default_factory=list, max_length=MAX_LIST_ITEMS)
    creator_note: Note | None = None
    source_clip_id: ItemId | None = None
    source_start_ms: int | None = Field(default=None, ge=0)
    source_end_ms: int | None = Field(default=None, ge=0)
    evidence_origin: EvidenceOrigin = "creator_authored"


class DraftPatch(BaseModel):
    """Partial update: only fields present in the request body are applied. ``null`` clears a
    scalar; ``null`` for an array field is a 422 (send ``[]`` to empty it). Arrays replace
    whole. Read-only Draft fields are accepted and ignored so a client may echo a whole Draft
    back; any other unknown key is rejected. Every text field goes through ``check_text``."""

    model_config = ConfigDict(extra="forbid")

    title: Title | None = None
    summary: Summary | None = None
    tags: list[Tag] = Field(default_factory=list, max_length=MAX_TAGS)
    cover_image_url: str | None = None
    servings: int | None = Field(default=None, ge=0, le=1000)
    prep_minutes: int | None = Field(default=None, ge=0, le=7 * 24 * 60)
    cook_minutes: int | None = Field(default=None, ge=0, le=7 * 24 * 60)
    ingredients: list[DraftIngredientIn] = Field(default_factory=list, max_length=MAX_INGREDIENTS)
    steps: list[DraftStepIn] = Field(default_factory=list, max_length=MAX_STEPS)
    creator_notes: list[ListItem] = Field(default_factory=list, max_length=MAX_LIST_ITEMS)
    dietary_warnings: list[ListItem] = Field(default_factory=list, max_length=MAX_LIST_ITEMS)

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
