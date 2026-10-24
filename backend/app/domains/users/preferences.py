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
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import ValidationError
from app.db.models import User, UserPreference
from app.domains.matching.dictionary import IngredientDictionary, load_dictionary
from app.domains.recipes.draft_schemas import check_text
from app.domains.safety.content import (
    Sensitivity,
    normalize_preferences,
    sensitivities,
    unrecognized,
)

ENTRY_MAX = 60
ENTRIES_MAX = 30
KEYS_MAX = 60  # stored foods per list after splitting (fix round 3, M5)

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
    for field_name, keys in (("allergies", allergies), ("avoid", avoid)):
        if len(keys) > KEYS_MAX:
            raise ValidationError(
                f"{field_name} expands to {len(keys)} foods after splitting entries like "
                f"'peanut and tree nut'; at most {KEYS_MAX} are allowed",
                extra={"fields": [field_name]},
            )
    now = datetime.now(UTC)
    # One statement for first-time and repeat saves, so two concurrent first PUTs never race on
    # the primary key (fix round 3, M4).
    stmt = pg_insert(UserPreference).values(
        user_id=user.id, allergies=allergies, avoid=avoid, updated_at=now
    )
    stmt = stmt.on_conflict_do_update(
        index_elements=[UserPreference.user_id],
        set_={"allergies": allergies, "avoid": avoid, "updated_at": now},
    )
    await session.execute(stmt)
    row = await session.get(UserPreference, user.id, populate_existing=True)
    return to_out(row, dictionary)


async def profile(session: AsyncSession, user: User) -> Profile:
    return await profile_for(session, user.id)


async def profile_for(session: AsyncSession, user_id: uuid.UUID) -> Profile:
    row = await session.get(UserPreference, user_id)
    dictionary = await load_dictionary(session) if row and (row.allergies or row.avoid) else None
    allergy_labels = list(row.allergies) if row else []
    avoid_labels = list(row.avoid) if row else []
    return Profile(
        allergy_labels=allergy_labels,
        avoid_labels=avoid_labels,
        allergies=sensitivities(allergy_labels, dictionary),
        avoid=sensitivities(avoid_labels, dictionary),
    )
