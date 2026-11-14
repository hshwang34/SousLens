"""Creator / follow DTOs (brief 015 API contract)."""

from __future__ import annotations

import uuid

from pydantic import BaseModel

from app.domains.recipes.schemas import RecipeCard


class CreatorSummary(BaseModel):
    id: uuid.UUID
    display_name: str
    bio: str | None
    avatar_url: str | None
    recipe_count: int
    follower_count: int
    is_following: bool
    cuisines: list[str]
    sample_recipe_titles: list[str]


class CreatorList(BaseModel):
    items: list[CreatorSummary]


class CreatorProfile(BaseModel):
    creator: CreatorSummary
    recipes: list[RecipeCard]
