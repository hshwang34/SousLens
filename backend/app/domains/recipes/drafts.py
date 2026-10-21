"""Creator authoring: drafts, publish rules, the transactional publish, edit and unpublish
(REC-03..06, brief 003).

Invariants enforced here (CLAUDE.md):

* A draft is owned; anyone else's draft is a 404 (``get_owned_or_404``).
* Publishing appends an immutable ``recipe_versions`` row (``version_number`` = previous + 1),
  points ``recipes.latest_version_id`` at it and marks the draft ``published``. The stored
  ingredient/step/warning JSON is byte-for-byte what the public detail endpoint serialises.
* A published draft is read-only (PATCH → 409). Editing a published recipe starts a *new* draft
  pre-filled from the latest version; there is never an in-place mutation of a version.
* Unpublish only flips ``recipes.visibility``; versions are untouched.
"""

from __future__ import annotations

import re
import uuid
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import NotFound, StateConflict, ValidationError
from app.db.models import DraftStatus, Recipe, RecipeDraft, RecipeVersion, User, Visibility
from app.domains.ownership import get_owned_or_404
from app.domains.recipes.draft_schemas import (
    CONTENT_FIELDS,
    TITLE_MAX,
    Draft,
    DraftContent,
    DraftPatch,
    DraftProblem,
    DraftStatusOut,
    DraftSummary,
    DraftValidation,
    PublishResult,
)
from app.domains.recipes.schemas import IngredientOut, StepOut

OPEN_DRAFT_STATUSES: tuple[DraftStatus, ...] = (
    DraftStatus.EDITING,
    DraftStatus.EXTRACTING,
    DraftStatus.REVIEW,
)
SLUG_MAX = 140


def share_url(base: str, recipe_id: uuid.UUID) -> str:
    return f"{base.rstrip('/')}/{recipe_id}"


# --------------------------------------------------------------------------- content


def read_content(row: RecipeDraft) -> DraftContent:
    return DraftContent.model_validate(row.structured_draft_json or {})


def normalise(content: DraftContent) -> dict[str, Any]:
    """Canonical stored form: full ingredient/step objects (every key present, defaults
    materialised) and step ``order`` rewritten to ``0..n-1`` from the array position."""
    steps = [
        StepOut.model_validate({**step.model_dump(), "order": index})
        for index, step in enumerate(content.steps)
    ]
    ingredients = [IngredientOut.model_validate(i.model_dump()) for i in content.ingredients]
    return {
        "title": content.title,
        "summary": content.summary,
        "tags": list(content.tags),
        "cover_image_url": content.cover_image_url,
        "servings": content.servings,
        "prep_minutes": content.prep_minutes,
        "cook_minutes": content.cook_minutes,
        "ingredients": [i.model_dump(mode="json") for i in ingredients],
        "steps": [s.model_dump(mode="json") for s in steps],
        "creator_notes": list(content.creator_notes),
        "dietary_warnings": list(content.dietary_warnings),
    }


def apply_patch(content: DraftContent, patch: DraftPatch) -> DraftContent:
    """Merge top-level fields that were present in the request; arrays replace whole."""
    provided = {
        name: getattr(patch, name) for name in patch.model_fields_set if name in CONTENT_FIELDS
    }
    merged = content.model_dump()
    for name, value in provided.items():
        if name == "steps":
            merged[name] = [{**step.model_dump(), "order": i} for i, step in enumerate(value)]
        elif name == "ingredients":
            merged[name] = [item.model_dump() for item in value]
        else:
            merged[name] = value
    return DraftContent.model_validate(merged)


# --------------------------------------------------------------------------- publish rules


def validate(content: DraftContent) -> DraftValidation:
    """The publish rules from the brief 003 contract (REC-04). Pure; safe to call on every
    response so the editor can show inline reasons."""
    problems: list[DraftProblem] = []

    title = (content.title or "").strip()
    if not title:
        problems.append(DraftProblem(field="title", message="Add a title"))
    elif len(title) > TITLE_MAX:
        problems.append(
            DraftProblem(field="title", message=f"Title must be {TITLE_MAX} characters or fewer")
        )

    if content.servings is None or content.servings < 1:
        problems.append(DraftProblem(field="servings", message="Servings must be at least 1"))

    ingredient_ids: set[str] = set()
    named = 0
    for index, ingredient in enumerate(content.ingredients):
        if ingredient.id in ingredient_ids:
            problems.append(
                DraftProblem(
                    field=f"ingredients[{index}].id",
                    message=f"Duplicate ingredient id '{ingredient.id}'",
                )
            )
        ingredient_ids.add(ingredient.id)
        if ingredient.name.strip():
            named += 1
        else:
            problems.append(
                DraftProblem(
                    field=f"ingredients[{index}].name",
                    message=f"Ingredient {index + 1} needs a name",
                )
            )
    if named == 0:
        problems.append(DraftProblem(field="ingredients", message="Add at least one ingredient"))

    step_ids: set[str] = set()
    instructed = 0
    for index, step in enumerate(content.steps):
        if step.id in step_ids:
            problems.append(
                DraftProblem(field=f"steps[{index}].id", message=f"Duplicate step id '{step.id}'")
            )
        step_ids.add(step.id)
        if step.instruction.strip():
            instructed += 1
        else:
            problems.append(
                DraftProblem(
                    field=f"steps[{index}].instruction",
                    message=f"Step {index + 1} needs an instruction",
                )
            )
        if step.order != index:
            problems.append(
                DraftProblem(
                    field=f"steps[{index}].order",
                    message=f"Step {index + 1} has order {step.order}; expected {index}",
                )
            )
        unknown = [ref for ref in step.ingredient_refs if ref not in ingredient_ids]
        if unknown:
            problems.append(
                DraftProblem(
                    field=f"steps[{index}].ingredient_refs",
                    message=f"Step {index + 1} references unknown ingredient "
                    + ", ".join(f"'{ref}'" for ref in unknown),
                )
            )
    if instructed == 0:
        problems.append(DraftProblem(field="steps", message="Add at least one step"))

    return DraftValidation(publishable=not problems, problems=problems)


# --------------------------------------------------------------------------- DTOs


def _status_out(row: RecipeDraft) -> DraftStatusOut:
    # DB statuses other than ``published`` (editing, and later extracting/review) are all an
    # open draft from the client's point of view (brief 003 contract: ``draft|published``).
    return "published" if row.status == DraftStatus.PUBLISHED else "draft"


def to_draft(row: RecipeDraft) -> Draft:
    content = read_content(row)
    return Draft(
        id=row.id,
        recipe_id=row.recipe_id,
        status=_status_out(row),
        validation=validate(content),
        created_at=row.created_at,
        updated_at=row.updated_at,
        **content.model_dump(),
    )


def to_summary(row: RecipeDraft) -> DraftSummary:
    content = read_content(row)
    return DraftSummary(
        id=row.id,
        recipe_id=row.recipe_id,
        status=_status_out(row),
        title=content.title,
        summary=content.summary,
        tags=content.tags,
        cover_image_url=content.cover_image_url,
        servings=content.servings,
        prep_minutes=content.prep_minutes,
        cook_minutes=content.cook_minutes,
        ingredient_count=len(content.ingredients),
        step_count=len(content.steps),
        validation=validate(content),
        created_at=row.created_at,
        updated_at=row.updated_at,
    )


# --------------------------------------------------------------------------- CRUD


async def get_draft_row(session: AsyncSession, user: User, draft_id: uuid.UUID) -> RecipeDraft:
    return await get_owned_or_404(session, RecipeDraft, draft_id, user.id, label="Draft")


async def create_draft(session: AsyncSession, user: User, patch: DraftPatch) -> RecipeDraft:
    content = apply_patch(DraftContent(), patch)
    row = RecipeDraft(
        owner_user_id=user.id,
        structured_draft_json=normalise(content),
        status=DraftStatus.EDITING,
    )
    session.add(row)
    await session.flush()
    await session.refresh(row)
    return row


async def list_drafts(session: AsyncSession, user: User) -> list[RecipeDraft]:
    stmt = (
        select(RecipeDraft)
        .where(RecipeDraft.owner_user_id == user.id)
        .order_by(RecipeDraft.updated_at.desc(), RecipeDraft.id.desc())
    )
    return list((await session.execute(stmt)).scalars().all())


async def patch_draft(
    session: AsyncSession, user: User, draft_id: uuid.UUID, patch: DraftPatch
) -> RecipeDraft:
    row = await get_draft_row(session, user, draft_id)
    if row.status == DraftStatus.PUBLISHED:
        raise StateConflict(
            "This draft was published and is read-only; edit the recipe to start a new draft",
            extra={"details": {"recipe_id": str(row.recipe_id) if row.recipe_id else None}},
        )
    row.structured_draft_json = normalise(apply_patch(read_content(row), patch))
    await session.flush()
    await session.refresh(row)
    return row


async def delete_draft(session: AsyncSession, user: User, draft_id: uuid.UUID) -> None:
    row = await get_draft_row(session, user, draft_id)
    await session.delete(row)
    await session.flush()


# --------------------------------------------------------------------------- publish


def slugify(title: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return slug[:SLUG_MAX].strip("-") or "recipe"


async def _unique_slug(session: AsyncSession, base: str) -> str:
    taken = set(
        (
            await session.execute(
                select(Recipe.slug).where(
                    (Recipe.slug == base) | Recipe.slug.like(f"{base}-%", escape="\\")
                )
            )
        )
        .scalars()
        .all()
    )
    if base not in taken:
        return base
    suffix = 2
    while f"{base}-{suffix}" in taken:
        suffix += 1
    return f"{base}-{suffix}"


def search_text_for(title: str, ingredients: list[dict[str, Any]]) -> str:
    names = " ".join(str(i.get("name", "")).strip() for i in ingredients)
    return " ".join(part for part in (title.strip(), names) if part).lower()


async def publish(
    session: AsyncSession, user: User, draft_id: uuid.UUID, *, share_url_base: str
) -> PublishResult:
    """One transaction: lock the draft, validate, create the recipe on first publish, append
    the version, point ``latest_version_id`` at it, mark the draft published."""
    row = (
        await session.execute(
            select(RecipeDraft)
            .where(RecipeDraft.id == draft_id, RecipeDraft.owner_user_id == user.id)
            .with_for_update()
        )
    ).scalar_one_or_none()
    if row is None:
        raise NotFound("Draft not found")
    if row.status == DraftStatus.PUBLISHED:
        raise StateConflict(
            "This draft was already published; edit the recipe to publish a new version",
            extra={"details": {"recipe_id": str(row.recipe_id) if row.recipe_id else None}},
        )
    content = read_content(row)
    normalised = normalise(content)
    row.structured_draft_json = normalised
    verdict = validate(content)
    if not verdict.publishable:
        raise ValidationError(
            "Draft is not ready to publish",
            extra={"details": {"problems": [p.model_dump() for p in verdict.problems]}},
        )
    title = (content.title or "").strip()

    recipe: Recipe | None = None
    if row.recipe_id is not None:
        recipe = (
            await session.execute(
                select(Recipe)
                .where(Recipe.id == row.recipe_id, Recipe.owner_user_id == user.id)
                .with_for_update(of=Recipe)  # eager joins are outer joins; lock recipes only
            )
        ).scalar_one_or_none()
        if recipe is None:
            raise NotFound("Recipe not found")
    if recipe is None:
        recipe = Recipe(
            owner_user_id=user.id,
            slug=await _unique_slug(session, slugify(title)),
            visibility=Visibility.PRIVATE,
            title=title,
        )
        session.add(recipe)
        await session.flush()

    next_number = (
        await session.execute(
            select(func.coalesce(func.max(RecipeVersion.version_number), 0) + 1).where(
                RecipeVersion.recipe_id == recipe.id
            )
        )
    ).scalar_one()
    version = RecipeVersion(
        recipe_id=recipe.id,
        version_number=next_number,
        servings=normalised["servings"],
        prep_minutes=normalised["prep_minutes"],
        cook_minutes=normalised["cook_minutes"],
        ingredient_json=normalised["ingredients"],
        step_json=normalised["steps"],
        warning_json={
            "creator_notes": normalised["creator_notes"],
            "dietary_warnings": normalised["dietary_warnings"],
        },
        search_text=search_text_for(title, normalised["ingredients"]),
    )
    session.add(version)
    await session.flush()

    recipe.title = title
    recipe.summary = normalised["summary"]
    recipe.tags = normalised["tags"]
    recipe.cover_image_url = normalised["cover_image_url"]
    recipe.latest_version_id = version.id
    recipe.visibility = Visibility.PUBLIC
    recipe.published_at = recipe.published_at or datetime.now(UTC)
    row.recipe_id = recipe.id
    row.status = DraftStatus.PUBLISHED
    await session.flush()
    return PublishResult(
        recipe_id=recipe.id,
        recipe_version_id=version.id,
        version_number=version.version_number,
        share_url=share_url(share_url_base, recipe.id),
    )


# --------------------------------------------------------------------------- edit / unpublish


async def open_draft_id(session: AsyncSession, recipe_id: uuid.UUID) -> uuid.UUID | None:
    stmt = (
        select(RecipeDraft.id)
        .where(RecipeDraft.recipe_id == recipe_id, RecipeDraft.status.in_(OPEN_DRAFT_STATUSES))
        .order_by(RecipeDraft.updated_at.desc())
        .limit(1)
    )
    return (await session.execute(stmt)).scalar_one_or_none()


async def start_edit(session: AsyncSession, user: User, recipe_id: uuid.UUID) -> RecipeDraft:
    recipe = await get_owned_or_404(session, Recipe, recipe_id, user.id, label="Recipe")
    version = recipe.latest_version
    if version is None:
        raise NotFound("Recipe not found")
    existing = await open_draft_id(session, recipe.id)
    if existing is not None:
        raise StateConflict(
            "A draft for this recipe is already open",
            extra={"details": {"draft_id": str(existing)}},
        )
    warnings = version.warning_json or {}
    content = DraftContent(
        title=recipe.title,
        summary=recipe.summary,
        tags=list(recipe.tags),
        cover_image_url=recipe.cover_image_url,
        servings=version.servings,
        prep_minutes=version.prep_minutes,
        cook_minutes=version.cook_minutes,
        ingredients=version.ingredient_json,
        steps=version.step_json,
        creator_notes=list(warnings.get("creator_notes", [])),
        dietary_warnings=list(warnings.get("dietary_warnings", [])),
    )
    row = RecipeDraft(
        owner_user_id=user.id,
        recipe_id=recipe.id,
        structured_draft_json=normalise(content),
        status=DraftStatus.EDITING,
    )
    session.add(row)
    await session.flush()
    await session.refresh(row)
    return row


async def unpublish(session: AsyncSession, user: User, recipe_id: uuid.UUID) -> Recipe:
    recipe = await get_owned_or_404(session, Recipe, recipe_id, user.id, label="Recipe")
    recipe.visibility = Visibility.PRIVATE
    await session.flush()
    return recipe
