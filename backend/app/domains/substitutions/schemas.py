"""Substitution DTOs (brief 005 contract, PRD §8.4)."""

from __future__ import annotations

import uuid
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from app.ai.notice import AINotice, notice_field


class SuggestIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    recipe_version_id: uuid.UUID
    ingredient_ref: str = Field(min_length=1, max_length=64)


class AdjustedStep(BaseModel):
    step_id: str
    instruction: str


class SuggestionOut(BaseModel):
    suggestion_id: uuid.UUID
    source: Literal["rule", "ai"]
    candidate: str
    kind: Literal["close_equivalent", "flavor_adaptation", "structural_substitution"]
    ratio_or_amount: str
    rationale: str
    impact_flavor: str
    impact_texture: str
    adjusted_steps: list[AdjustedStep]
    confidence: Literal["high", "medium", "low"]
    risks: list[str]
    allergy_warning: str | None = None
    requires_user_confirmation: Literal[True] = True


class SuggestOut(BaseModel):
    recipe_version_id: uuid.UUID
    ingredient_ref: str
    target_ingredient: str
    suggestions: list[SuggestionOut]
    cannot_substitute: bool
    reason: str | None
    safety_notice: str | None
    ai_notice: AINotice | None = notice_field()  # brief 007; omitted unless set
