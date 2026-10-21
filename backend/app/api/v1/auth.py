"""Dev sign-in (AUTH-01, DECISIONS #5). Route exists only when ``AUTH_MODE=dev``."""

from __future__ import annotations

from fastapi import APIRouter, Request

from app.core.errors import NotFound
from app.core.security import DevAuthProvider, SettingsDep, create_access_token
from app.db.engine import DbSession
from app.domains.users.schemas import DevLoginRequest, TokenResponse, UserOut

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/dev-login", response_model=TokenResponse)
async def dev_login(
    payload: DevLoginRequest, request: Request, session: DbSession, settings: SettingsDep
) -> TokenResponse:
    provider: DevAuthProvider | None = getattr(request.app.state, "auth_provider", None)
    if settings.auth_mode != "dev" or provider is None:
        # Backstop: the router is only mounted in dev mode (see create_app).
        raise NotFound("Not found")
    user = await provider.authenticate(
        session, email=payload.email, display_name=payload.display_name
    )
    await session.commit()
    token = create_access_token(settings, user.id)
    return TokenResponse(access_token=token, user=UserOut.from_model(user))
