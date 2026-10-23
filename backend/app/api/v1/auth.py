"""Dev sign-in (AUTH-01, DECISIONS #5). This router is only mounted when ``AUTH_MODE=dev``.

Two steps: ``POST /auth/dev-login`` issues a challenge whose 6-digit code is printed to the
server log; ``POST /auth/dev-login/verify`` exchanges challenge id + code for a JWT. The user
row is created on successful verification, never on challenge creation.
"""

from __future__ import annotations

from fastapi import APIRouter, Request, status

from app.core.errors import NotFound
from app.core.security import DevAuthProvider, SettingsDep, create_access_token
from app.db.engine import DbSession
from app.domains.users import dev_login
from app.domains.users.schemas import (
    DevLoginChallengeResponse,
    DevLoginRequest,
    DevLoginVerifyRequest,
    TokenResponse,
    UserOut,
)

router = APIRouter(prefix="/auth", tags=["auth"])


def _provider(request: Request, settings_auth_mode: str) -> DevAuthProvider:
    provider: DevAuthProvider | None = getattr(request.app.state, "auth_provider", None)
    if settings_auth_mode != "dev" or provider is None:
        # Backstop: the router is only mounted in dev mode (see create_app).
        raise NotFound("Not found")
    return provider


@router.post(
    "/dev-login",
    response_model=DevLoginChallengeResponse,
    response_model_exclude_none=True,
    status_code=status.HTTP_202_ACCEPTED,
)
async def start_dev_login(
    payload: DevLoginRequest, request: Request, session: DbSession, settings: SettingsDep
) -> DevLoginChallengeResponse:
    _provider(request, settings.auth_mode)
    issued = await dev_login.create_challenge(session, settings, payload.email)
    await session.commit()
    echo = settings.dev_login_echo_code and settings.environment == "test"
    return DevLoginChallengeResponse(
        challenge_id=issued.challenge_id,
        expires_in_seconds=int(dev_login.TTL.total_seconds()),
        code=issued.code if echo else None,
    )


@router.post("/dev-login/verify", response_model=TokenResponse)
async def verify_dev_login(
    payload: DevLoginVerifyRequest, request: Request, session: DbSession, settings: SettingsDep
) -> TokenResponse:
    provider = _provider(request, settings.auth_mode)
    email = await dev_login.verify_challenge(session, settings, payload.challenge_id, payload.code)
    user = await provider.authenticate(session, email=email, display_name=None)
    await session.commit()
    token = create_access_token(settings, user.id)
    return TokenResponse(access_token=token, user=UserOut.from_model(user))
