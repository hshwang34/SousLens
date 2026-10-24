"""Food preferences (SUB-02, brief 005 contract): allergies are hard blocks, "avoid" is soft.

Entries are parsed (split on commas / "and"; "allergic to", "no", "-free", "intolerant" are
stripped) and normalised against the allergen classes in ``domains/safety/content.py`` and the
ingredient dictionary ("peanuts" → ``peanut``, "tree nuts" → ``tree nuts``, "lactose
intolerant" → ``milk``, "gluten free" → ``gluten``), deduplicated, and stored in that form.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from functools import partial
from typing import Annotated

from pydantic import BaseModel, BeforeValidator, ConfigDict, Field, StringConstraints
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import User, UserPreference
from app.domains.matching.dictionary import IngredientDictionary
from app.domains.recipes.draft_schemas import check_text
from app.domains.safety.content import (
    Sensitivity,
    normalize_preferences,
    sensitivities,
    unrecognized,
)

ENTRY_MAX = 60
ENTRIES_MAX = 30

Entry = Annotated[
    str,
    BeforeValidator(partial(check_text, multiline=False, trim=True)),
    StringConstraints(min_length=1, max_length=ENTRY_MAX),
]


class PreferencesIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    allergies: list[Entry] = Field(default_factory=list, max_length=ENTRIES_MAX)
    avoid: list[Entry] = Field(default_factory=list, max_length=ENTRIES_MAX)


class PreferencesOut(BaseModel):
    allergies: list[str]
    avoid: list[str]
    updated_at: datetime | None
    # Stored entries that map to neither an allergen class nor a dictionary food. Still stored
    # and matched word by word as a fallback; the app should ask the user to check them.
    unrecognized: list[str] = []


class Profile(BaseModel):
    """Resolved for matching (not an API shape)."""

    model_config = ConfigDict(arbitrary_types_allowed=True)

    allergy_labels: list[str]
    avoid_labels: list[str]
    allergies: list[Sensitivity]
    avoid: list[Sensitivity]


def to_out(
    row: UserPreference | None, dictionary: IngredientDictionary | None = None
) -> PreferencesOut:
    if row is None:
        return PreferencesOut(allergies=[], avoid=[], updated_at=None, unrecognized=[])
    labels = [*row.allergies, *row.avoid]
    return PreferencesOut(
        allergies=list(row.allergies),
        avoid=list(row.avoid),
        updated_at=row.updated_at,
        unrecognized=unrecognized(labels, dictionary) if dictionary is not None else [],
    )


async def get_row(session: AsyncSession, user: User) -> UserPreference | None:
    return await session.get(UserPreference, user.id)


async def put(
    session: AsyncSession, user: User, body: PreferencesIn, dictionary: IngredientDictionary
) -> PreferencesOut:
    allergies = normalize_preferences(body.allergies, dictionary)
    # An allergy already blocks harder than "avoid"; keep each food in one list only.
    avoid = [a for a in normalize_preferences(body.avoid, dictionary) if a not in allergies]
    row = await get_row(session, user)
    now = datetime.now(UTC)
    if row is None:
        row = UserPreference(user_id=user.id, allergies=allergies, avoid=avoid, updated_at=now)
        session.add(row)
    else:
        row.allergies, row.avoid, row.updated_at = allergies, avoid, now
    await session.flush()
    return to_out(row, dictionary)


async def profile(session: AsyncSession, user: User) -> Profile:
    return await profile_for(session, user.id)


async def profile_for(session: AsyncSession, user_id: uuid.UUID) -> Profile:
    row = await session.get(UserPreference, user_id)
    allergy_labels = list(row.allergies) if row else []
    avoid_labels = list(row.avoid) if row else []
    return Profile(
        allergy_labels=allergy_labels,
        avoid_labels=avoid_labels,
        allergies=sensitivities(allergy_labels),
        avoid=sensitivities(avoid_labels),
    )
