"""Two-step dev sign-in: challenge (code in the server log) → verify (token).

Flow (DECISIONS #5, dev mode only):

1. ``create_challenge(email)`` generates a 6-digit code with :mod:`secrets`, stores only an HMAC
   of it, logs the code once on the ``souslens.devlogin`` logger and returns the challenge id.
   No user row is created here.
2. ``verify_challenge(challenge_id, code)`` compares in constant time, allows at most
   ``MAX_ATTEMPTS`` tries, expires after ``TTL``, is single use, and returns the email. The
   caller then creates/loads the user (race-safe) and issues the JWT.

Every failure is the same ``Unauthorized("Invalid or expired sign-in code")`` so a caller cannot
tell unknown / expired / consumed / wrong apart.
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import secrets
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.errors import Unauthorized
from app.db.models import DevLoginChallenge

log = logging.getLogger("souslens.devlogin")

TTL = timedelta(minutes=10)
MAX_ATTEMPTS = 5
MAX_OPEN_PER_EMAIL = 5
CODE_DIGITS = 6
INVALID_MESSAGE = "Invalid or expired sign-in code"


@dataclass(frozen=True, slots=True)
class IssuedChallenge:
    challenge_id: uuid.UUID
    email: str
    code: str
    expires_at: datetime


def normalize_email(email: str) -> str:
    return email.strip().lower()


def hash_code(settings: Settings, challenge_id: uuid.UUID, code: str) -> str:
    message = f"{challenge_id}:{code}".encode()
    return hmac.new(settings.jwt_secret.encode("utf-8"), message, hashlib.sha256).hexdigest()


def _now() -> datetime:
    return datetime.now(UTC)


async def create_challenge(
    session: AsyncSession, settings: Settings, email: str
) -> IssuedChallenge:
    normalized = normalize_email(email)
    now = _now()
    await _cap_open_challenges(session, normalized, now)

    challenge_id = uuid.uuid4()
    code = f"{secrets.randbelow(10**CODE_DIGITS):0{CODE_DIGITS}d}"
    challenge = DevLoginChallenge(
        id=challenge_id,
        email=normalized,
        code_hash=hash_code(settings, challenge_id, code),
        attempts=0,
        expires_at=now + TTL,
    )
    session.add(challenge)
    await session.flush()
    # The ONE place a code is visible. Dev mode only; see app/core/logging.py.
    log.info(
        "dev sign-in code",
        extra={"email": normalized, "code": code, "challenge_id": str(challenge_id)},
    )
    return IssuedChallenge(
        challenge_id=challenge_id, email=normalized, code=code, expires_at=challenge.expires_at
    )


async def _cap_open_challenges(session: AsyncSession, email: str, now: datetime) -> None:
    """Keep at most ``MAX_OPEN_PER_EMAIL - 1`` open challenges so the new one is the fifth."""
    stmt = (
        select(DevLoginChallenge)
        .where(
            DevLoginChallenge.email == email,
            DevLoginChallenge.consumed_at.is_(None),
            DevLoginChallenge.expires_at > now,
        )
        .order_by(DevLoginChallenge.created_at.asc(), DevLoginChallenge.id.asc())
        .with_for_update()
    )
    open_challenges = list((await session.execute(stmt)).scalars().all())
    excess = len(open_challenges) - (MAX_OPEN_PER_EMAIL - 1)
    for stale in open_challenges[: max(excess, 0)]:
        stale.consumed_at = now  # invalidated, never usable again
    if excess > 0:
        await session.flush()


async def verify_challenge(
    session: AsyncSession, settings: Settings, challenge_id: uuid.UUID, code: str
) -> str:
    """Return the challenge's email on success; raise ``Unauthorized`` otherwise.

    Failed attempts are committed before raising so a retry cannot reset the counter.
    """
    now = _now()
    challenge = (
        await session.execute(
            select(DevLoginChallenge).where(DevLoginChallenge.id == challenge_id).with_for_update()
        )
    ).scalar_one_or_none()
    if challenge is None:
        raise Unauthorized(INVALID_MESSAGE)
    if (
        challenge.consumed_at is not None
        or challenge.expires_at <= now
        or challenge.attempts >= MAX_ATTEMPTS
    ):
        raise Unauthorized(INVALID_MESSAGE)

    challenge.attempts += 1
    expected = challenge.code_hash
    provided = hash_code(settings, challenge.id, code)
    if not hmac.compare_digest(expected, provided):
        await session.commit()  # persist the failed attempt even though we raise
        raise Unauthorized(INVALID_MESSAGE)

    challenge.consumed_at = now
    await session.flush()
    return challenge.email
