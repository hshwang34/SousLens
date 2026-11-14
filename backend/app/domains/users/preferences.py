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
from typing import Annotated, Literal

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


# Brief 015 taste profile: closed vocabularies, soft ranking signals only (never safety).
Diet = Literal["vegetarian", "vegan", "pescatarian", "halal", "kosher"]
Cuisine = Literal[
    "korean",
    "italian",
    "mexican",
    "indian",
    "japanese",
    "chinese",
    "thai",
    "american",
    "mediterranean",
    "french",
]
SkillLevel = Literal["beginner", "comfortable", "confident"]
TASTE_FIELDS = ("diets", "cuisines", "skill_level")


class PreferencesIn(BaseModel):
    """``allergies``/``avoid`` replace as before. An omitted taste field keeps its stored value,
    so clients that predate brief 015 never wipe it; ``[]``/``null`` clears it."""

    model_config = ConfigDict(extra="forbid")

    allergies: list[Entry] = Field(default_factory=list, max_length=ENTRIES_MAX)
    avoid: list[Entry] = Field(default_factory=list, max_length=ENTRIES_MAX)
    diets: list[Diet] | None = Field(default=None, max_length=5)
    cuisines: list[Cuisine] | None = Field(default=None, max_length=10)
    skill_level: SkillLevel | None = None


class PreferencesOut(BaseModel):
    allergies: list[str]
    avoid: list[str]
    diets: list[str] = []
    cuisines: list[str] = []
    skill_level: str | None = None
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
        diets=list(row.diets),
        cuisines=list(row.cuisines),
        skill_level=row.skill_level,
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
    values: dict[str, object] = {"allergies": allergies, "avoid": avoid, "updated_at": now}
    for name in TASTE_FIELDS:
        if name in body.model_fields_set:
            value = getattr(body, name)
            values[name] = list(dict.fromkeys(value or [])) if name != "skill_level" else value
    # One statement for first-time and repeat saves, so two concurrent first PUTs never race on
    # the primary key (fix round 3, M4).
    stmt = pg_insert(UserPreference).values(
        user_id=user.id,
        diets=values.get("diets", []),
        cuisines=values.get("cuisines", []),
        **{k: v for k, v in values.items() if k not in ("diets", "cuisines")},
    )
    stmt = stmt.on_conflict_do_update(index_elements=[UserPreference.user_id], set_=values)
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
