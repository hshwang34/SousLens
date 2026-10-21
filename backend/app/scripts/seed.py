"""Seed ``fixtures/seeded_recipes/*.json`` into the database, idempotently.

* Upsert by ``slug``; mutable metadata (title, summary, tags, cover) is refreshed. Visibility is
  set to public only when the recipe is first created.
* Content is published as version 1 the first time only. Published versions are immutable, so a
  re-run never touches an existing version (edit → new version is a Slice 1 flow).
* Owned by the seeded creator ``creator@souslens.dev``.
* IDs and ``published_at`` are deterministic (uuid5) so ``fixtures/expected_outputs`` stays stable.

Run: ``uv run python -m app.scripts.seed`` (or ``make seed``).
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings, get_settings
from app.core.logging import configure_logging
from app.db.engine import make_engine, make_sessionmaker
from app.db.models import Recipe, RecipeVersion, Visibility
from app.domains.recipes.schemas import IngredientOut, StepOut
from app.domains.users import service as users_service

log = logging.getLogger("souslens.seed")

SEED_CREATOR_EMAIL = "creator@souslens.dev"
SEED_NAMESPACE = uuid.UUID("6f1c2a4e-9d3b-4b8e-9a7c-2d5e8f0b1c3a")
SEED_PUBLISHED_AT = datetime(2026, 10, 15, 0, 0, 0, tzinfo=UTC)


class SeedCreator(BaseModel):
    model_config = ConfigDict(extra="forbid")

    display_name: str


class SeedIngredient(IngredientOut):
    model_config = ConfigDict(extra="forbid")


class SeedStep(StepOut):
    model_config = ConfigDict(extra="forbid")


class SeedRecipe(BaseModel):
    """Fixture shape: RecipeDetail minus ids/dates (PRD §10.1)."""

    model_config = ConfigDict(extra="forbid")

    slug: str = Field(pattern=r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
    title: str
    summary: str | None = None
    tags: list[str] = Field(default_factory=list)
    cover_image_url: str | None = None
    creator: SeedCreator
    servings: int = Field(ge=1)
    prep_minutes: int | None = Field(default=None, ge=0)
    cook_minutes: int | None = Field(default=None, ge=0)
    ingredients: list[SeedIngredient]
    steps: list[SeedStep]
    creator_notes: list[str] = Field(default_factory=list)
    dietary_warnings: list[str] = Field(default_factory=list)


@dataclass(frozen=True, slots=True)
class SeedResult:
    slug: str
    recipe_id: uuid.UUID
    version_id: uuid.UUID
    created_recipe: bool
    created_version: bool


def seed_uuid(kind: str, key: str) -> uuid.UUID:
    return uuid.uuid5(SEED_NAMESPACE, f"{kind}:{key}")


def load_fixtures(fixtures_dir: Path) -> list[SeedRecipe]:
    folder = fixtures_dir / "seeded_recipes"
    return [
        SeedRecipe.model_validate(json.loads(path.read_text(encoding="utf-8")))
        for path in sorted(folder.glob("*.json"))
    ]


async def seed_recipe(session: AsyncSession, fixture: SeedRecipe) -> SeedResult:
    creator = await users_service.get_or_create_by_email(
        session,
        email=SEED_CREATOR_EMAIL,
        display_name=fixture.creator.display_name,
        auth_provider="dev",
        user_id=seed_uuid("user", SEED_CREATOR_EMAIL),
    )
    recipe = (
        await session.execute(select(Recipe).where(Recipe.slug == fixture.slug))
    ).scalar_one_or_none()
    created_recipe = recipe is None
    if recipe is None:
        recipe = Recipe(
            id=seed_uuid("recipe", fixture.slug),
            owner_user_id=creator.id,
            slug=fixture.slug,
            visibility=Visibility.PUBLIC,
            title=fixture.title,
        )
        session.add(recipe)
    # Mutable metadata is refreshed; visibility is only set at creation so an operator who
    # unpublished a seeded recipe does not get it re-published by a re-run.
    recipe.title = fixture.title
    recipe.summary = fixture.summary
    recipe.tags = list(fixture.tags)
    recipe.cover_image_url = fixture.cover_image_url
    await session.flush()

    created_version = recipe.latest_version_id is None
    if created_version:
        version = RecipeVersion(
            id=seed_uuid("version", f"{fixture.slug}:1"),
            recipe_id=recipe.id,
            version_number=1,
            servings=fixture.servings,
            prep_minutes=fixture.prep_minutes,
            cook_minutes=fixture.cook_minutes,
            ingredient_json=[i.model_dump(mode="json") for i in fixture.ingredients],
            step_json=[s.model_dump(mode="json") for s in fixture.steps],
            warning_json={
                "creator_notes": list(fixture.creator_notes),
                "dietary_warnings": list(fixture.dietary_warnings),
            },
        )
        session.add(version)
        await session.flush()
        recipe.latest_version_id = version.id
        recipe.published_at = recipe.published_at or SEED_PUBLISHED_AT
        await session.flush()
        version_id = version.id
    else:
        assert recipe.latest_version_id is not None
        version_id = recipe.latest_version_id

    return SeedResult(
        slug=fixture.slug,
        recipe_id=recipe.id,
        version_id=version_id,
        created_recipe=created_recipe,
        created_version=created_version,
    )


async def seed_fixtures(session: AsyncSession, fixtures_dir: Path) -> list[SeedResult]:
    results = [await seed_recipe(session, fixture) for fixture in load_fixtures(fixtures_dir)]
    await session.commit()
    return results


async def run(settings: Settings | None = None) -> list[SeedResult]:
    settings = settings or get_settings()
    engine = make_engine(settings.database_url)
    try:
        async with make_sessionmaker(engine)() as session:
            results = await seed_fixtures(session, settings.fixtures_dir)
    finally:
        await engine.dispose()
    for r in results:
        log.info(
            "seeded recipe",
            extra={
                "slug": r.slug,
                "recipe_id": str(r.recipe_id),
                "version_id": str(r.version_id),
                "created_recipe": r.created_recipe,
                "created_version": r.created_version,
            },
        )
    return results


def main() -> None:
    configure_logging(get_settings().log_level)
    asyncio.run(run())


if __name__ == "__main__":
    main()
