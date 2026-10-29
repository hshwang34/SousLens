"""Canonical recipe JSON (PRD §10.1, schema_version 1.0) and the discover card."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

SCHEMA_VERSION = "1.0"

EvidenceOrigin = Literal["creator_authored", "creator_reviewed", "ai_extracted"]


def _absent(value: object) -> bool:
    return value is None


class CreatorRef(BaseModel):
    id: uuid.UUID
    display_name: str


class IngredientOut(BaseModel):
    """Read/output model: tolerant of additive stored fields (write paths subclass with forbid)."""

    model_config = ConfigDict(extra="ignore")

    id: str
    name: str
    quantity: float | None = None
    unit: str | None = None
    optional: bool = False
    preparation: str | None = None
    notes: str | None = None
    # Brief 008: set on ingredients that came from video extraction ("ai_extracted"), or that
    # the creator published from one ("creator_reviewed"). Omitted (not null) otherwise, so
    # hand-authored and seeded recipes serialise exactly as before.
    evidence_origin: EvidenceOrigin | None = Field(default=None, exclude_if=_absent)


class StepOut(BaseModel):
    model_config = ConfigDict(extra="ignore")

    id: str
    order: int = Field(ge=0)
    instruction: str
    ingredient_refs: list[str] = Field(default_factory=list)
    estimated_minutes: int | None = None
    success_cues: list[str] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)
    creator_note: str | None = None
    source_clip_id: str | None = None
    source_start_ms: int | None = None
    source_end_ms: int | None = None
    evidence_origin: EvidenceOrigin = "creator_authored"


class RecipeCard(BaseModel):
    recipe_id: uuid.UUID
    slug: str
    title: str
    summary: str | None
    tags: list[str]
    creator: CreatorRef
    servings: int
    prep_minutes: int | None
    cook_minutes: int | None
    cover_image_url: str | None
    published_at: datetime
    recipe_version_id: uuid.UUID
    version_number: int
    saved: bool | None = None
    """``true``/``false`` for an authenticated caller, ``null`` when anonymous (REC-02)."""


class MyRecipe(RecipeCard):
    """``GET /me/recipes`` row: a card plus the owner-only state (brief 003 contract)."""

    visibility: Literal["public", "private", "unlisted"]
    has_open_draft: bool


class RecipeDetail(BaseModel):
    schema_version: Literal["1.0"] = SCHEMA_VERSION
    recipe_id: uuid.UUID
    recipe_version_id: uuid.UUID
    version_number: int
    slug: str
    title: str
    summary: str | None
    tags: list[str]
    creator: CreatorRef
    creator_id: uuid.UUID
    servings: int
    prep_minutes: int | None
    cook_minutes: int | None
    cover_image_url: str | None
    ingredients: list[IngredientOut]
    steps: list[StepOut]
    creator_notes: list[str]
    dietary_warnings: list[str]
    published_at: datetime
    share_url: str
    saved: bool | None = None


class RecipePage(BaseModel):
    items: list[RecipeCard]
    next_cursor: str | None


class RecipeCardList(BaseModel):
    items: list[RecipeCard]


class MyRecipeList(BaseModel):
    items: list[MyRecipe]


class SaveStatus(BaseModel):
    recipe_id: uuid.UUID
    saved: bool


class UnpublishResult(BaseModel):
    recipe_id: uuid.UUID
    visibility: Literal["private"] = "private"


class RecipeContent(BaseModel):
    """Content block read back from ``recipe_versions``. Tolerant: an additive stored field must
    never 500 a public GET. Write paths validate with the strict seed/draft models instead."""

    model_config = ConfigDict(extra="ignore")

    servings: int = Field(ge=1)
    prep_minutes: int | None = Field(default=None, ge=0)
    cook_minutes: int | None = Field(default=None, ge=0)
    ingredients: list[IngredientOut]
    steps: list[StepOut]
    creator_notes: list[str] = Field(default_factory=list)
    dietary_warnings: list[str] = Field(default_factory=list)
