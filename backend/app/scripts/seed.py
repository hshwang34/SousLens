"""Seed ``fixtures/ingredients.json`` and ``fixtures/seeded_recipes/*.json``, idempotently.

* Substitution rules (brief 005): ``fixtures/substitution_rules.json`` upserted by target
  canonical name; stale rows removed.
* Ingredients (brief 004): upserted by ``canonical_name`` with deterministic uuid5 ids; aliases,
  category, allergens, qualifiers and ambiguity links are refreshed on every run. Rows no longer
  in the file are deleted (pantry items keep their ``normalized_name``; ``ingredient_id`` goes
  null via ON DELETE SET NULL), so a stale alias can never collide with a current one. The
  resulting table is then re-read and checked strictly for alias collisions.

* Upsert by ``slug``; mutable metadata (title, summary, tags, cover) is refreshed. Visibility is
  set to public only when the recipe is first created.
* Published versions are immutable: a re-run never touches an existing version. When a fixture's
  content differs from the latest version it is published as the next version;
  ``seeded_recipes/history/<slug>/v<N>.json`` holds earlier contents so fresh and existing
  databases end up with identical versions (brief 005: the gochujang marinade fix is v2).
* Owned by the seeded creator ``creator@souslens.dev``.
* IDs are deterministic (uuid5) and each fixture carries its own ``published_at`` so
  ``fixtures/expected_outputs`` (and the feed order) stays stable.

Run: ``uv run python -m app.scripts.seed`` (or ``make seed``).
"""

from __future__ import annotations

import asyncio
import json
import logging
import sys
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
from app.db.models import Ingredient, Recipe, RecipeVersion, SubstitutionRule, Visibility
from app.domains.matching.dictionary import (
    IngredientDictionary,
    entries_from_file,
    entry_from_row,
    read_dictionary_file,
)
from app.domains.recipes.drafts import search_text_for
from app.domains.recipes.schemas import IngredientOut, StepOut
from app.domains.substitutions.rules import read_rules_file
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
    published_at: datetime = SEED_PUBLISHED_AT


@dataclass(frozen=True, slots=True)
class SeedResult:
    slug: str
    recipe_id: uuid.UUID
    version_id: uuid.UUID
    created_recipe: bool
    created_version: bool
    conflict: bool = False  # fixture differs from the latest version with no history to cover it


def seed_uuid(kind: str, key: str) -> uuid.UUID:
    return uuid.uuid5(SEED_NAMESPACE, f"{kind}:{key}")


def load_fixtures(fixtures_dir: Path) -> list[SeedRecipe]:
    folder = fixtures_dir / "seeded_recipes"
    return [
        SeedRecipe.model_validate(json.loads(path.read_text(encoding="utf-8")))
        for path in sorted(folder.glob("*.json"))
    ]


def _fixture_content(fixture: SeedRecipe) -> dict[str, object]:
    ingredients = [i.model_dump(mode="json") for i in fixture.ingredients]
    return {
        "servings": fixture.servings,
        "prep_minutes": fixture.prep_minutes,
        "cook_minutes": fixture.cook_minutes,
        "ingredient_json": ingredients,
        "step_json": [st.model_dump(mode="json") for st in fixture.steps],
        "warning_json": {
            "creator_notes": list(fixture.creator_notes),
            "dietary_warnings": list(fixture.dietary_warnings),
        },
        "title": fixture.title,
        "summary": fixture.summary,
        "tags": list(fixture.tags),
        "cover_image_url": fixture.cover_image_url,
    }


def _content(version: RecipeVersion) -> dict[str, object]:
    return {
        "servings": version.servings,
        "prep_minutes": version.prep_minutes,
        "cook_minutes": version.cook_minutes,
        "ingredient_json": version.ingredient_json,
        "step_json": version.step_json,
        "warning_json": version.warning_json,
        "title": version.title,
        "summary": version.summary,
        "tags": list(version.tags or []),
        "cover_image_url": version.cover_image_url,
    }


def _version_row(
    recipe_id: uuid.UUID, slug: str, number: int, fixture: SeedRecipe
) -> RecipeVersion:
    content = _fixture_content(fixture)
    return RecipeVersion(
        id=seed_uuid("version", f"{slug}:{number}"),
        recipe_id=recipe_id,
        version_number=number,
        search_text=search_text_for(fixture.title, content["ingredient_json"]),  # type: ignore[arg-type]
        **content,
    )


def load_history(fixtures_dir: Path, slug: str) -> list[SeedRecipe]:
    folder = fixtures_dir / "seeded_recipes" / "history" / slug
    paths = sorted(folder.glob("v*.json"), key=lambda p: int(p.stem[1:])) if folder.is_dir() else []
    return [SeedRecipe.model_validate(json.loads(p.read_text(encoding="utf-8"))) for p in paths]


async def seed_recipe(
    session: AsyncSession, fixture: SeedRecipe, history: list[SeedRecipe] | None = None
) -> SeedResult:
    history = history or []
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

    # Published versions are immutable: when the fixture's content differs from the latest
    # version, publish the next version instead of rewriting it (brief 005 fix round 1).
    # ``history/<slug>/v<N>.json`` keeps earlier contents so a fresh database and an existing
    # one converge on the same versions with the same deterministic ids.
    created_version = False
    latest = (
        await session.get(RecipeVersion, recipe.latest_version_id)
        if recipe.latest_version_id
        else None
    )
    for number, content in enumerate([*history, fixture], start=1):
        if latest is not None and number <= latest.version_number:
            continue
        if latest is not None and _content(latest) == _fixture_content(content):
            break  # the latest version already has this content
        version = _version_row(recipe.id, fixture.slug, number, content)
        session.add(version)
        await session.flush()
        recipe.latest_version_id = version.id
        recipe.published_at = recipe.published_at or fixture.published_at
        await session.flush()
        latest = version
        created_version = True
    assert latest is not None
    version_id = latest.id
    # The fixture says something the latest published version does not, and no history file
    # turns that into a new version: refuse loudly rather than skip or rewrite (fix round 2).
    conflict = _content(latest) != _fixture_content(fixture)
    if conflict:
        log.warning(
            "seed fixture differs from the latest published version; add the published content "
            "as seeded_recipes/history/<slug>/v<N>.json to publish the fixture as a new version",
            extra={"slug": fixture.slug, "latest_version": latest.version_number},
        )

    return SeedResult(
        slug=fixture.slug,
        recipe_id=recipe.id,
        version_id=version_id,
        created_recipe=created_recipe,
        created_version=created_version,
        conflict=conflict,
    )


@dataclass(frozen=True, slots=True)
class IngredientSeedResult:
    created: int
    updated: int
    unchanged: int
    removed: int = 0


async def seed_ingredients(session: AsyncSession, fixtures_dir: Path) -> IngredientSeedResult:
    entries = entries_from_file(read_dictionary_file(fixtures_dir))
    IngredientDictionary.build(entries)  # strict: refuses alias collisions before any write
    existing = {
        row.canonical_name: row for row in (await session.execute(select(Ingredient))).scalars()
    }
    created = updated = unchanged = 0
    for entry in entries:
        values = {
            "aliases_json": list(entry.aliases),
            "category": entry.category,
            "allergen_flags": list(entry.allergens),
            "qualifiers": sorted(entry.qualifiers),
            "ambiguous_with": list(entry.ambiguous_with),
        }
        row = existing.get(entry.canonical_name)
        if row is None:
            session.add(
                Ingredient(
                    id=seed_uuid("ingredient", entry.canonical_name),
                    canonical_name=entry.canonical_name,
                    **values,
                )
            )
            created += 1
        elif any(getattr(row, k) != v for k, v in values.items()):
            for k, v in values.items():
                setattr(row, k, v)
            updated += 1
        else:
            unchanged += 1
    wanted = {e.canonical_name for e in entries}
    stale = [row for name, row in existing.items() if name not in wanted]
    for row in stale:
        await session.delete(row)
    await session.flush()
    rows = (await session.execute(select(Ingredient))).scalars().all()
    IngredientDictionary.build([entry_from_row(r) for r in rows])  # strict over the DB too
    log.info(
        "seeded ingredients",
        extra={
            "ingredients_created": created,
            "ingredients_updated": updated,
            "ingredients_unchanged": unchanged,
        },
    )
    return IngredientSeedResult(
        created=created, updated=updated, unchanged=unchanged, removed=len(stale)
    )


@dataclass(frozen=True, slots=True)
class RuleSeedResult:
    created: int
    updated: int
    unchanged: int
    removed: int


async def seed_substitution_rules(session: AsyncSession, fixtures_dir: Path) -> RuleSeedResult:
    """Upsert ``fixtures/substitution_rules.json`` (brief 005) keyed on the target's dictionary
    canonical name; rows no longer in the file are deleted. Every target must be a dictionary
    entry, so a typo fails the seed instead of silently never matching."""
    data = read_rules_file(fixtures_dir)
    dictionary = IngredientDictionary.build(entries_from_file(read_dictionary_file(fixtures_dir)))
    unknown = [r.target for r in data.rules if dictionary.get(r.target) is None]
    if unknown:
        raise ValueError(f"substitution rule targets not in the dictionary: {unknown}")
    existing = {
        row.target: row for row in (await session.execute(select(SubstitutionRule))).scalars()
    }
    created = updated = unchanged = 0
    for rule in data.rules:
        payload = rule.model_dump(mode="json")
        row = existing.get(rule.target)
        if row is None:
            session.add(
                SubstitutionRule(
                    id=seed_uuid("substitution_rule", rule.target),
                    target=rule.target,
                    rule_json=payload,
                )
            )
            created += 1
        elif row.rule_json != payload:
            row.rule_json = payload
            updated += 1
        else:
            unchanged += 1
    wanted = {r.target for r in data.rules}
    stale = [row for target, row in existing.items() if target not in wanted]
    for row in stale:
        await session.delete(row)
    await session.flush()
    log.info(
        "seeded substitution rules",
        extra={"rules_created": created, "rules_updated": updated, "rules_unchanged": unchanged},
    )
    return RuleSeedResult(created, updated, unchanged, len(stale))


async def seed_fixtures(session: AsyncSession, fixtures_dir: Path) -> list[SeedResult]:
    await seed_ingredients(session, fixtures_dir)
    await seed_substitution_rules(session, fixtures_dir)
    results = [
        await seed_recipe(session, fixture, load_history(fixtures_dir, fixture.slug))
        for fixture in load_fixtures(fixtures_dir)
    ]
    await session.commit()
    conflicts = [r.slug for r in results if r.conflict]
    if conflicts:
        # Everything else is seeded and committed; published versions were never touched.
        raise SeedConflict(conflicts)
    return results


class SeedConflict(RuntimeError):
    """A fixture differs from its latest published version and no history file covers it."""

    def __init__(self, slugs: list[str]) -> None:
        super().__init__(
            "fixture content differs from the latest published version (no history file): "
            + ", ".join(slugs)
        )
        self.slugs = slugs


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
    try:
        asyncio.run(run())
    except SeedConflict as exc:
        log.error("seed refused", extra={"slugs": exc.slugs})
        print(f"seed: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc


if __name__ == "__main__":
    main()
