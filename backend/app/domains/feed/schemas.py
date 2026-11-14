"""Feed DTOs (brief 015 API contract)."""

from __future__ import annotations

from pydantic import BaseModel

from app.domains.recipes.schemas import RecipeCard


class FeedInfo(BaseModel):
    reason: str  # display as is: "You have 8 of 9", "Korean", "From Mina", "New"
    coverage: float | None  # 0 to 1; null when the pantry is empty
    can_make: bool
    allergy_conflict: str | None  # e.g. "peanut" → the app shows "Contains peanut"


class FeedCard(RecipeCard):
    feed: FeedInfo | None = None


class FeedPage(BaseModel):
    items: list[FeedCard]
    next_cursor: str | None
