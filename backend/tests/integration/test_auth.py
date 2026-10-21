"""AUTH-01: dev login, /me, 401 envelope, non-dev mode hides the route."""

from __future__ import annotations

import uuid

import pytest
from httpx import AsyncClient
from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.security import create_access_token
from app.db.models import User
from app.domains.users import service as users_service
from tests.conftest import dev_login


async def test_dev_login_creates_user_and_me_returns_it(client: AsyncClient) -> None:
    response = await client.post(
        "/v1/auth/dev-login", json={"email": "Tester@Example.com", "display_name": None}
    )
    assert response.status_code == 200
    body = response.json()
    assert body["token_type"] == "bearer"
    assert set(body["user"]) == {"id", "display_name", "preference_units", "created_at"}
    assert body["user"]["display_name"] == "tester"
    assert body["user"]["preference_units"] == "us"

    me = await client.get("/v1/me", headers={"Authorization": f"Bearer {body['access_token']}"})
    assert me.status_code == 200
    assert me.json() == body["user"]


async def test_dev_login_is_idempotent_per_email(client: AsyncClient) -> None:
    first = await client.post(
        "/v1/auth/dev-login", json={"email": "same@example.com", "display_name": "Sam"}
    )
    second = await client.post(
        "/v1/auth/dev-login", json={"email": "SAME@example.com", "display_name": "Other"}
    )
    assert first.json()["user"]["id"] == second.json()["user"]["id"]
    assert second.json()["user"]["display_name"] == "Sam"


async def test_dev_login_rejects_bad_email(client: AsyncClient) -> None:
    response = await client.post("/v1/auth/dev-login", json={"email": "not-an-email"})
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"


async def test_two_users_get_distinct_identities(client: AsyncClient) -> None:
    token_a = await dev_login(client, "a@example.com")
    token_b = await dev_login(client, "b@example.com")
    me_a = await client.get("/v1/me", headers={"Authorization": f"Bearer {token_a}"})
    me_b = await client.get("/v1/me", headers={"Authorization": f"Bearer {token_b}"})
    assert me_a.json()["id"] != me_b.json()["id"]


async def test_missing_token_is_401_envelope(client: AsyncClient) -> None:
    response = await client.get("/v1/me", headers={"X-Correlation-Id": "cid-401"})
    assert response.status_code == 401
    body = response.json()["error"]
    assert body["code"] == "UNAUTHORIZED"
    assert body["retryable"] is False
    assert body["correlation_id"] == "cid-401"
    assert response.headers["x-correlation-id"] == "cid-401"


async def test_invalid_token_is_401(client: AsyncClient) -> None:
    response = await client.get("/v1/me", headers={"Authorization": "Bearer nope"})
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "UNAUTHORIZED"


async def test_non_bearer_scheme_is_401(client: AsyncClient) -> None:
    response = await client.get("/v1/me", headers={"Authorization": "Basic abc"})
    assert response.status_code == 401


async def test_dev_login_404_outside_dev_mode(apple_mode_client: AsyncClient) -> None:
    response = await apple_mode_client.post(
        "/v1/auth/dev-login", json={"email": "tester@example.com"}
    )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "NOT_FOUND"


async def test_dev_login_route_does_not_exist_outside_dev_mode(
    apple_mode_client: AsyncClient,
) -> None:
    # Invalid body: a mounted route would answer 422; the path must not exist at all.
    bad_body = await apple_mode_client.post("/v1/auth/dev-login", json={"email": "nope"})
    assert bad_body.status_code == 404
    assert bad_body.json()["error"]["code"] == "NOT_FOUND"
    # GET: a mounted POST-only route would answer 405.
    get = await apple_mode_client.get("/v1/auth/dev-login")
    assert get.status_code == 404
    assert get.json()["error"]["code"] == "NOT_FOUND"
    # The rest of the API is unaffected.
    assert (await apple_mode_client.get("/v1/health")).status_code == 200


async def test_token_for_unknown_user_is_401(client: AsyncClient, settings: Settings) -> None:
    token = create_access_token(settings, uuid.uuid4())
    response = await client.get("/v1/me", headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "UNAUTHORIZED"


async def test_token_for_deleted_user_is_401(client: AsyncClient, db_session: AsyncSession) -> None:
    token = await dev_login(client, "gone@example.com")
    headers = {"Authorization": f"Bearer {token}"}
    assert (await client.get("/v1/me", headers=headers)).status_code == 200
    await db_session.execute(delete(User).where(User.email == "gone@example.com"))
    await db_session.commit()
    response = await client.get("/v1/me", headers=headers)
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "UNAUTHORIZED"


async def test_first_login_race_loser_reuses_winners_row(
    db_session: AsyncSession, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Two concurrent first logins: the loser's SELECT misses, then its INSERT conflicts."""
    winner = await users_service.get_or_create_by_email(
        db_session, email="race@example.com", display_name="Winner", auth_provider="dev"
    )
    await db_session.commit()
    real_find = users_service.find_by_subject
    calls = {"n": 0}

    async def find_missing_first(session: AsyncSession, **kwargs: str) -> User | None:
        calls["n"] += 1
        if calls["n"] == 1:
            return None  # the loser's SELECT ran before the winner's COMMIT
        return await real_find(session, **kwargs)

    monkeypatch.setattr(users_service, "find_by_subject", find_missing_first)
    loser = await users_service.get_or_create_by_email(
        db_session, email="race@example.com", display_name="Loser", auth_provider="dev"
    )
    assert loser.id == winner.id
    assert loser.display_name == "Winner"
    assert calls["n"] == 2
    # the session is still usable after the savepoint rollback
    assert await users_service.get_by_id(db_session, winner.id) is not None
