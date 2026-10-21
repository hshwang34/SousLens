"""AUTH-01 / DECISIONS #5: two-step dev login (code in the server log), /me, 401 envelope,
non-dev mode hides both routes."""

from __future__ import annotations

import asyncio
import logging
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from httpx import ASGITransport, AsyncClient, Response
from sqlalchemy import delete, func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.security import create_access_token
from app.db.models import DevLoginChallenge, User
from app.domains.users import dev_login as dev_login_service
from app.domains.users import service as users_service
from app.main import create_app
from tests.conftest import dev_sign_in, start_dev_sign_in

VERIFY = "/v1/auth/dev-login/verify"
INVALID = "Invalid or expired sign-in code"


async def verify(client: AsyncClient, challenge_id: str, code: str) -> Response:
    return await client.post(VERIFY, json={"challenge_id": challenge_id, "code": code})


async def user_count(db_session: AsyncSession) -> int:
    return (await db_session.execute(select(func.count()).select_from(User))).scalar_one()


def wrong_code(challenge: dict[str, str]) -> str:
    return "000000" if challenge["code"] != "000000" else "111111"


def assert_invalid_code(response: Response) -> None:
    assert response.status_code == 401, response.text
    body = response.json()["error"]
    assert body["code"] == "UNAUTHORIZED"
    assert body["message"] == INVALID
    assert body["retryable"] is False


# --- happy path ---------------------------------------------------------------------------


async def test_challenge_then_verify_creates_user_and_me_returns_it(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    challenge = await start_dev_sign_in(client, "Tester@Example.com")
    assert set(challenge) == {"challenge_id", "expires_in_seconds", "hint", "code"}
    assert challenge["expires_in_seconds"] == 600
    assert challenge["hint"] == "Check the server log for your sign-in code."
    assert len(challenge["code"]) == 6 and challenge["code"].isdigit()
    uuid.UUID(challenge["challenge_id"])
    assert await user_count(db_session) == 0, "no user until the code is verified"

    response = await verify(client, challenge["challenge_id"], challenge["code"])
    assert response.status_code == 200, response.text
    body = response.json()
    assert set(body) == {"access_token", "token_type", "user"}
    assert body["token_type"] == "bearer"
    assert set(body["user"]) == {"id", "display_name", "preference_units", "created_at"}
    assert body["user"]["display_name"] == "tester"
    assert body["user"]["preference_units"] == "us"
    assert await user_count(db_session) == 1

    me = await client.get("/v1/me", headers={"Authorization": f"Bearer {body['access_token']}"})
    assert me.status_code == 200
    assert me.json() == body["user"]


async def test_code_is_logged_once_on_the_devlogin_logger(
    client: AsyncClient, caplog: pytest.LogCaptureFixture
) -> None:
    with caplog.at_level(logging.INFO, logger="souslens.devlogin"):
        challenge = await start_dev_sign_in(client, "logged@example.com")
    records = [r for r in caplog.records if r.name == "souslens.devlogin"]
    assert len(records) == 1
    record = records[0]
    logged = {"email": record.email, "code": record.code, "challenge_id": record.challenge_id}  # type: ignore[attr-defined]
    assert record.getMessage() == "dev sign-in code"
    assert logged == {
        "email": "logged@example.com",
        "code": challenge["code"],
        "challenge_id": challenge["challenge_id"],
    }
    # the logged code is the one that works
    assert (await verify(client, challenge["challenge_id"], logged["code"])).status_code == 200


async def test_code_is_not_echoed_unless_test_env_opts_in(settings: Settings) -> None:
    app = create_app(settings.model_copy(update={"dev_login_echo_code": False}))
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            response = await client.post("/v1/auth/dev-login", json={"email": "quiet@example.com"})
    assert response.status_code == 202
    assert set(response.json()) == {"challenge_id", "expires_in_seconds", "hint"}


async def test_sign_in_is_idempotent_per_email_and_case_insensitive(client: AsyncClient) -> None:
    token_a = await dev_sign_in(client, "same@example.com")
    token_b = await dev_sign_in(client, "SAME@example.com")
    me_a = await client.get("/v1/me", headers={"Authorization": f"Bearer {token_a}"})
    me_b = await client.get("/v1/me", headers={"Authorization": f"Bearer {token_b}"})
    assert me_a.json()["id"] == me_b.json()["id"]


async def test_two_users_get_distinct_identities(client: AsyncClient) -> None:
    token_a = await dev_sign_in(client, "a@example.com")
    token_b = await dev_sign_in(client, "b@example.com")
    me_a = await client.get("/v1/me", headers={"Authorization": f"Bearer {token_a}"})
    me_b = await client.get("/v1/me", headers={"Authorization": f"Bearer {token_b}"})
    assert me_a.json()["id"] != me_b.json()["id"]


async def test_code_hash_is_keyed_and_never_the_plain_code(
    client: AsyncClient, db_session: AsyncSession, settings: Settings
) -> None:
    challenge = await start_dev_sign_in(client, "hash@example.com")
    row = await db_session.get(DevLoginChallenge, uuid.UUID(challenge["challenge_id"]))
    assert row is not None
    assert challenge["code"] not in row.code_hash
    assert row.code_hash == dev_login_service.hash_code(settings, row.id, challenge["code"])
    assert row.attempts == 0 and row.consumed_at is None


# --- validation ---------------------------------------------------------------------------


@pytest.mark.parametrize("payload", [{"email": "not-an-email"}, {}, {"email": ""}])
async def test_challenge_rejects_bad_email(client: AsyncClient, payload: dict[str, str]) -> None:
    response = await client.post("/v1/auth/dev-login", json=payload)
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"


@pytest.mark.parametrize(
    "payload",
    [
        {},
        {"challenge_id": "not-a-uuid", "code": "123456"},
        {"challenge_id": str(uuid.uuid4()), "code": "12345"},
        {"challenge_id": str(uuid.uuid4()), "code": "1234567"},
        {"challenge_id": str(uuid.uuid4()), "code": "12a456"},
        {"challenge_id": str(uuid.uuid4())},
    ],
)
async def test_verify_rejects_malformed_payload(
    client: AsyncClient, payload: dict[str, str]
) -> None:
    response = await client.post(VERIFY, json=payload)
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"


# --- refusals: all identical 401s ----------------------------------------------------------


async def test_wrong_code_is_401_and_does_not_create_user(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    challenge = await start_dev_sign_in(client, "wrong@example.com")
    assert_invalid_code(await verify(client, challenge["challenge_id"], wrong_code(challenge)))
    assert await user_count(db_session) == 0
    # the right code still works afterwards (attempt 2 of 5)
    assert (await verify(client, challenge["challenge_id"], challenge["code"])).status_code == 200


async def test_unknown_challenge_is_401(client: AsyncClient) -> None:
    assert_invalid_code(await verify(client, str(uuid.uuid4()), "123456"))


async def test_expired_challenge_is_401(client: AsyncClient, db_session: AsyncSession) -> None:
    challenge = await start_dev_sign_in(client, "late@example.com")
    await db_session.execute(
        update(DevLoginChallenge)
        .where(DevLoginChallenge.id == uuid.UUID(challenge["challenge_id"]))
        .values(expires_at=datetime.now(UTC) - timedelta(seconds=1))
    )
    await db_session.commit()
    assert_invalid_code(await verify(client, challenge["challenge_id"], challenge["code"]))


async def test_challenge_is_single_use(client: AsyncClient) -> None:
    challenge = await start_dev_sign_in(client, "once@example.com")
    assert (await verify(client, challenge["challenge_id"], challenge["code"])).status_code == 200
    assert_invalid_code(await verify(client, challenge["challenge_id"], challenge["code"]))


async def test_sixth_attempt_is_refused_even_with_the_right_code(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    challenge = await start_dev_sign_in(client, "brute@example.com")
    for _ in range(dev_login_service.MAX_ATTEMPTS):
        assert_invalid_code(await verify(client, challenge["challenge_id"], wrong_code(challenge)))
    row = await db_session.get(DevLoginChallenge, uuid.UUID(challenge["challenge_id"]))
    assert row is not None and row.attempts == dev_login_service.MAX_ATTEMPTS
    assert_invalid_code(await verify(client, challenge["challenge_id"], challenge["code"]))
    assert await user_count(db_session) == 0


async def test_failed_attempts_are_persisted_across_requests(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    challenge = await start_dev_sign_in(client, "count@example.com")
    await verify(client, challenge["challenge_id"], wrong_code(challenge))
    await verify(client, challenge["challenge_id"], wrong_code(challenge))
    row = await db_session.get(DevLoginChallenge, uuid.UUID(challenge["challenge_id"]))
    assert row is not None and row.attempts == 2


async def test_sixth_open_challenge_invalidates_the_oldest(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    email = "many@example.com"
    challenges = [await start_dev_sign_in(client, email) for _ in range(6)]
    open_count = (
        await db_session.execute(
            select(func.count())
            .select_from(DevLoginChallenge)
            .where(DevLoginChallenge.email == email, DevLoginChallenge.consumed_at.is_(None))
        )
    ).scalar_one()
    assert open_count == dev_login_service.MAX_OPEN_PER_EMAIL
    oldest, second, newest = challenges[0], challenges[1], challenges[-1]
    assert_invalid_code(await verify(client, oldest["challenge_id"], oldest["code"]))
    assert (await verify(client, newest["challenge_id"], newest["code"])).status_code == 200
    # challenges 2..5 are still open and independent of each other
    assert (await verify(client, second["challenge_id"], second["code"])).status_code == 200


async def test_challenge_cap_is_per_email(client: AsyncClient) -> None:
    other = await start_dev_sign_in(client, "other@example.com")
    for _ in range(6):
        await start_dev_sign_in(client, "noisy@example.com")
    assert (await verify(client, other["challenge_id"], other["code"])).status_code == 200


# --- bearer verification ------------------------------------------------------------------


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


async def test_token_for_unknown_user_is_401(client: AsyncClient, settings: Settings) -> None:
    token = create_access_token(settings, uuid.uuid4())
    response = await client.get("/v1/me", headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "UNAUTHORIZED"


async def test_token_for_deleted_user_is_401(client: AsyncClient, db_session: AsyncSession) -> None:
    token = await dev_sign_in(client, "gone@example.com")
    headers = {"Authorization": f"Bearer {token}"}
    assert (await client.get("/v1/me", headers=headers)).status_code == 200
    await db_session.execute(delete(User).where(User.email == "gone@example.com"))
    await db_session.commit()
    response = await client.get("/v1/me", headers=headers)
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "UNAUTHORIZED"


# --- non-dev mode: neither route exists ---------------------------------------------------


@pytest.mark.parametrize(
    ("method", "path", "payload"),
    [
        ("POST", "/v1/auth/dev-login", {"email": "tester@example.com"}),
        ("POST", "/v1/auth/dev-login", {"email": "nope"}),  # invalid body: still 404, not 422
        ("GET", "/v1/auth/dev-login", None),  # not 405
        ("POST", VERIFY, {"challenge_id": str(uuid.uuid4()), "code": "123456"}),
        ("POST", VERIFY, {}),
        ("GET", VERIFY, None),
    ],
)
async def test_dev_login_routes_do_not_exist_outside_dev_mode(
    apple_mode_client: AsyncClient, method: str, path: str, payload: dict[str, str] | None
) -> None:
    response = await apple_mode_client.request(method, path, json=payload)
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "NOT_FOUND"
    assert (await apple_mode_client.get("/v1/health")).status_code == 200


# --- first-use race -----------------------------------------------------------------------


async def test_first_login_race_loser_reuses_winners_row(
    db_session: AsyncSession, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Two concurrent first verifications: the loser's SELECT misses, then its INSERT conflicts."""
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
    assert await users_service.get_by_id(db_session, winner.id) is not None


# --- brute-force budget (lockout, cooldown, purge, concurrency) --------------------------------


async def test_lockout_after_budget_spent_across_challenges(
    client: AsyncClient, settings: Settings
) -> None:
    """Fresh challenges must not reset the guess budget: 10 failures → 429 on the next challenge."""
    email = "victim@example.com"
    budget = settings.dev_login_max_failures_per_window
    spent = 0
    while spent < budget:
        challenge = await start_dev_sign_in(client, email)
        for _ in range(min(dev_login_service.MAX_ATTEMPTS, budget - spent)):
            assert_invalid_code(
                await verify(client, challenge["challenge_id"], wrong_code(challenge))
            )
            spent += 1
    locked = await client.post("/v1/auth/dev-login", json={"email": email})
    assert locked.status_code == 429
    body = locked.json()["error"]
    assert body["code"] == "RATE_LIMITED" and body["retryable"] is True
    # Another email is unaffected.
    assert (
        await client.post("/v1/auth/dev-login", json={"email": "bystander@example.com"})
    ).status_code == 202


async def test_lockout_lifts_after_window(
    client: AsyncClient, db_session: AsyncSession, settings: Settings
) -> None:
    email = "later@example.com"
    challenge = await start_dev_sign_in(client, email)
    for _ in range(dev_login_service.MAX_ATTEMPTS):
        await verify(client, challenge["challenge_id"], wrong_code(challenge))
    challenge = await start_dev_sign_in(client, email)
    for _ in range(dev_login_service.MAX_ATTEMPTS):
        await verify(client, challenge["challenge_id"], wrong_code(challenge))
    assert (await client.post("/v1/auth/dev-login", json={"email": email})).status_code == 429
    # Age every challenge out of the lockout window.
    stale = datetime.now(UTC) - timedelta(minutes=settings.dev_login_lockout_window_minutes + 1)
    await db_session.execute(
        update(DevLoginChallenge).where(DevLoginChallenge.email == email).values(created_at=stale)
    )
    await db_session.commit()
    assert (await client.post("/v1/auth/dev-login", json={"email": email})).status_code == 202


async def test_cooldown_between_challenges(settings: Settings, clean_tables: None) -> None:
    app = create_app(settings.model_copy(update={"dev_login_cooldown_seconds": 30}))
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            first = await client.post("/v1/auth/dev-login", json={"email": "cool@example.com"})
            assert first.status_code == 202
            second = await client.post("/v1/auth/dev-login", json={"email": "cool@example.com"})
            assert second.status_code == 429
            assert second.json()["error"]["code"] == "RATE_LIMITED"
            # Cooldown is per email.
            other = await client.post("/v1/auth/dev-login", json={"email": "warm@example.com"})
            assert other.status_code == 202


async def test_long_expired_challenges_are_purged(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    old = await start_dev_sign_in(client, "old@example.com")
    ancient = datetime.now(UTC) - dev_login_service.PURGE_AFTER - timedelta(hours=1)
    await db_session.execute(
        update(DevLoginChallenge)
        .where(DevLoginChallenge.id == uuid.UUID(old["challenge_id"]))
        .values(expires_at=ancient, created_at=ancient - dev_login_service.TTL)
    )
    await db_session.commit()
    await start_dev_sign_in(client, "new@example.com")  # any create purges
    assert await db_session.get(DevLoginChallenge, uuid.UUID(old["challenge_id"])) is None


async def test_concurrent_verifies_mint_exactly_one_token(client: AsyncClient) -> None:
    challenge = await start_dev_sign_in(client, "race@example.com")
    responses = await asyncio.gather(
        *(verify(client, challenge["challenge_id"], challenge["code"]) for _ in range(10))
    )
    statuses = sorted(r.status_code for r in responses)
    assert statuses.count(200) == 1 and statuses.count(401) == 9
