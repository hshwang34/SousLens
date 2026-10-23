"""Public user DTOs (snake_case JSON, shared with the iOS client)."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.db.models import User


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    display_name: str
    preference_units: Literal["us", "metric"]
    created_at: datetime

    @classmethod
    def from_model(cls, user: User) -> UserOut:
        return cls(
            id=user.id,
            display_name=user.display_name,
            preference_units=user.preference_units.value,
            created_at=user.created_at,
        )


_EMAIL_PATTERN = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"


class DevLoginRequest(BaseModel):
    """Step 1: ask for a one-time code. The code is written to the server log only."""

    email: str = Field(min_length=3, max_length=320, pattern=_EMAIL_PATTERN)

    @field_validator("email")
    @classmethod
    def _normalize_email(cls, value: str) -> str:
        return value.strip().lower()


class DevLoginChallengeResponse(BaseModel):
    challenge_id: uuid.UUID
    expires_in_seconds: int
    hint: str = "Check the server log for your sign-in code."
    code: str | None = Field(
        default=None,
        description="Only present when DEV_LOGIN_ECHO_CODE=true in the test environment.",
    )


class DevLoginVerifyRequest(BaseModel):
    """Step 2: prove possession of the logged code."""

    challenge_id: uuid.UUID
    code: str = Field(min_length=6, max_length=6, pattern=r"^[0-9]{6}$")


class TokenResponse(BaseModel):
    access_token: str
    token_type: Literal["bearer"] = "bearer"
    user: UserOut
