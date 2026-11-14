"""Brief 012 tier plumbing: every user carries a ``free`` / ``paid`` entitlement, set by config
(``DEFAULT_ENTITLEMENT``, ``paid`` for the beta), with no DB column."""

from __future__ import annotations

from collections.abc import AsyncIterator

import pytest
from httpx import ASGITransport, AsyncClient

from app.core.config import Settings
from app.main import create_app
from tests.conftest import dev_sign_in, start_dev_sign_in


@pytest.fixture
async def free_client(settings: Settings, clean_tables: None) -> AsyncIterator[AsyncClient]:
    app = create_app(settings.model_copy(update={"default_entitlement": "free"}))
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


async def test_beta_default_is_paid_on_me(client: AsyncClient) -> None:
    token = await dev_sign_in(client, "beta@example.com")
    me = await client.get("/v1/me", headers={"Authorization": f"Bearer {token}"})
    assert me.status_code == 200
    assert me.json()["entitlement"] == "paid"


async def test_sign_in_response_carries_the_same_entitlement(client: AsyncClient) -> None:
    challenge = await start_dev_sign_in(client, "verify@example.com")
    response = await client.post(
        "/v1/auth/dev-login/verify",
        json={"challenge_id": challenge["challenge_id"], "code": challenge["code"]},
    )
    assert response.status_code == 200
    assert response.json()["user"]["entitlement"] == "paid"


async def test_config_can_switch_everyone_to_free(free_client: AsyncClient) -> None:
    token = await dev_sign_in(free_client, "free@example.com")
    me = await free_client.get("/v1/me", headers={"Authorization": f"Bearer {token}"})
    assert me.json()["entitlement"] == "free"


def test_settings_default_and_validation() -> None:
    secret = "x" * 40
    assert Settings(jwt_secret=secret, auth_mode="dev").default_entitlement == "paid"
    with pytest.raises(ValueError):
        Settings(jwt_secret=secret, auth_mode="dev", default_entitlement="gold")  # type: ignore[arg-type]
