"""I/O wrapper around the pure ``fit``: loads the version (with the version access rule), the
caller's confirmed pantry and the seeded dictionary."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import PantryItem, RecipeVersion, User
from app.domains.matching.dictionary import load_dictionary
from app.domains.matching.fit import FitResult, PantryEntry, RecipeIngredient, fit
from app.domains.recipes import service as recipes_service
from app.domains.recipes.schemas import IngredientOut


def ingredients_of(version: RecipeVersion) -> list[RecipeIngredient]:
    return [
        RecipeIngredient(
            id=i.id, name=i.name, quantity=i.quantity, unit=i.unit, optional=i.optional
        )
        for i in (IngredientOut.model_validate(raw) for raw in version.ingredient_json or [])
    ]


async def load_pantry(session: AsyncSession, user: User) -> list[PantryEntry]:
    """The caller's confirmed pantry, as the pure ``fit`` reads it."""
    rows = (
        await session.execute(select(PantryItem).where(PantryItem.owner_user_id == user.id))
    ).scalars()
    return [
        PantryEntry(
            id=r.id,
            raw_label=r.raw_label,
            normalized_name=r.normalized_name,
            quantity=float(r.quantity) if r.quantity is not None else None,
            unit=r.unit,
            last_confirmed_at=r.last_confirmed_at,
            quantity_is_estimate=r.quantity_is_estimate,
        )
        for r in rows
    ]


async def fit_version(
    session: AsyncSession, user: User, version_id: uuid.UUID, now: datetime
) -> FitResult:
    version, _recipe, _saved = await recipes_service.get_accessible_version(
        session, version_id, user=user
    )
    pantry = await load_pantry(session, user)
    dictionary = await load_dictionary(session)
    return fit(version.id, ingredients_of(version), pantry, dictionary, now)
