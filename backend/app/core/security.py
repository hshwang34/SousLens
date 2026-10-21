"""JWT issuance/verification and the ``CurrentUser`` dependency (AUTH-01, SEC-01).

``AuthProvider`` is the seam where Sign in with Apple slots in later (DECISIONS #5). Dev login is
only reachable when ``AUTH_MODE=dev``; the router enforces that, this module just signs tokens.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import Annotated, Protocol

import jwt
from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.errors import Unauthorized
from app.db.engine import DbSession
from app.db.models import User
from app.domains.users import service as users_service

TOKEN_TYPE = "bearer"


def create_access_token(
    settings: Settings, user_id: uuid.UUID, *, now: datetime | None = None
) -> str:
    issued = now or datetime.now(UTC)
    payload = {
        "sub": str(user_id),
        "iat": int(issued.timestamp()),
        "exp": int((issued + timedelta(days=settings.jwt_ttl_days)).timestamp()),
        "iss": settings.app_name,
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def verify_access_token(settings: Settings, token: str) -> uuid.UUID:
    """Return the subject user id or raise ``Unauthorized``. Never leaks why beyond the code."""
    try:
        payload = jwt.decode(
            token,
            settings.jwt_secret,
            algorithms=[settings.jwt_algorithm],
            issuer=settings.app_name,
            options={"require": ["sub", "exp", "iat"]},
        )
        return uuid.UUID(str(payload["sub"]))
    except (jwt.PyJWTError, ValueError, KeyError) as exc:
        raise Unauthorized("Invalid or expired token") from exc


class AuthProvider(Protocol):
    """Resolves an external identity to a local ``User`` row."""

    name: str

    async def authenticate(
        self, session: AsyncSession, *, email: str, display_name: str | None
    ) -> User: ...


class DevAuthProvider:
    """Email-only sign-in for the pilot. Creates the user on first use."""

    name = "dev"

    async def authenticate(
        self, session: AsyncSession, *, email: str, display_name: str | None
    ) -> User:
        return await users_service.get_or_create_by_email(
            session, email=email, display_name=display_name, auth_provider=self.name
        )


def get_settings_dep(request: Request) -> Settings:
    return request.app.state.settings


SettingsDep = Annotated[Settings, Depends(get_settings_dep)]

_bearer = HTTPBearer(auto_error=False)


async def get_current_user(
    session: DbSession,
    settings: SettingsDep,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
) -> User:
    if credentials is None or credentials.scheme.lower() != TOKEN_TYPE:
        raise Unauthorized("Missing bearer token")
    user_id = verify_access_token(settings, credentials.credentials)
    user = await users_service.get_by_id(session, user_id)
    if user is None:
        raise Unauthorized("Unknown user")
    return user


CurrentUser = Annotated[User, Depends(get_current_user)]
