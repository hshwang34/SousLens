"""Gemini cost guard (brief 007, DECISIONS #18/#19).

* Every guarded call first **reserves** its worst-case ceiling in ``ai_usage`` (its own short
  transaction, committed before the call, so concurrent calls see each other). After the call
  the row is **settled** at the price of the reported ``usage_metadata``; a failed call is
  settled at what it is known to have cost (zero for a 4xx/5xx answer, the attempt's ceiling
  for a timeout or cancellation, because the provider may still bill those).
* Caps, checked atomically under one global advisory lock: per user $0.25 per UTC day, and a
  global UTC-month hard stop at $22. At $15 the month soft-degrades (``video_extraction_enabled``
  is false; Slice 5 reads it). A reservation that would cross a cap is refused and the caller
  falls back to the labelled mock path (``AINotice``). Nothing fails silently.
* A row that is never settled (a crash mid-call) keeps counting at its ceiling: fail closed.
* Video extraction (brief 008) has its own per-user cap (5 per UTC month, counted on jobs), so
  it is left out of the $0.25 per-user *day* check and sum: one 15-minute video's ceiling is
  above $0.25, and extracting a video must not use up the user's coach budget for the day. It
  still counts towards both monthly caps.
"""

from __future__ import annotations

import logging
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime
from decimal import Decimal
from typing import Any, Literal

from sqlalchemy import case, func, select, text, update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.ai.notice import DenialReason
from app.ai.pricing import cost_usd
from app.core.config import Settings
from app.db.models import AIUsage

log = logging.getLogger("souslens.ai.budget")

Capability = Literal[
    "coach", "inspect", "pantry_photo", "pantry_transcript", "substitution", "video"
]

_GLOBAL_LOCK_KEY = "souslens:ai_budget"
# ``status`` reports "resting" once less than about one interactive call's reservation is left.
STATUS_HEADROOM_USD = Decimal("0.05")


@dataclass
class UsageMeter:
    """Token usage of one guarded call, across all of its attempts."""

    model: str
    at: datetime
    input_tokens: int = 0
    output_tokens: int = 0
    thinking_tokens: int = 0
    attempts: int = 0
    unknown_usd: Decimal = field(default_factory=lambda: Decimal(0))

    def record(self, usage: Any) -> None:
        """``usage`` is a ``GenerateContentResponseUsageMetadata`` (or None)."""
        if usage is None:
            return
        self.input_tokens += int(getattr(usage, "prompt_token_count", 0) or 0)
        self.input_tokens += int(getattr(usage, "tool_use_prompt_token_count", 0) or 0)
        self.output_tokens += int(getattr(usage, "candidates_token_count", 0) or 0)
        self.thinking_tokens += int(getattr(usage, "thoughts_token_count", 0) or 0)

    def record_unknown(self, worst_usd: Decimal) -> None:
        """An attempt whose cost is unknown (timeout, cancelled, connection lost)."""
        self.unknown_usd += worst_usd

    @property
    def cost(self) -> Decimal:
        billed = cost_usd(
            self.model,
            self.at,
            input_tokens=self.input_tokens,
            output_tokens=self.output_tokens + self.thinking_tokens,  # thinking bills as output
        )
        return billed + self.unknown_usd


@dataclass(frozen=True)
class Reservation:
    id: uuid.UUID
    capability: str
    model: str
    ceiling: Decimal


@dataclass(frozen=True)
class Denial:
    reason: DenialReason


@dataclass(frozen=True)
class BudgetStatus:
    month_spent_usd: Decimal
    user_day_spent_usd: Decimal | None
    live: bool
    reason: DenialReason | None
    video_extraction_enabled: bool


def day_start(now: datetime) -> datetime:
    now = now.astimezone(UTC)
    return now.replace(hour=0, minute=0, second=0, microsecond=0)


def month_start(now: datetime) -> datetime:
    return day_start(now).replace(day=1)


def _spent_expr() -> Any:
    return func.coalesce(
        func.sum(case((AIUsage.status == "settled", AIUsage.cost_usd), else_=AIUsage.reserved_usd)),
        0,
    )


async def _spent(
    session: AsyncSession, since: datetime, user_id: uuid.UUID | None = None
) -> Decimal:
    stmt = select(_spent_expr()).where(AIUsage.created_at >= since)
    if user_id is not None:
        # The per-user day budget is for interactive features; video has its own count cap.
        stmt = stmt.where(AIUsage.user_id == user_id, AIUsage.capability != "video")
    return Decimal(await session.scalar(stmt) or 0)


class CostGuard:
    def __init__(self, sessionmaker: async_sessionmaker[AsyncSession], settings: Settings) -> None:
        self._sessionmaker = sessionmaker
        self.user_daily_cap = Decimal(str(settings.ai_user_daily_cap_usd))
        self.month_soft_cap = Decimal(str(settings.ai_month_soft_cap_usd))
        self.month_hard_cap = Decimal(str(settings.ai_month_hard_cap_usd))

    async def reserve(
        self,
        user_id: uuid.UUID,
        capability: Capability,
        model: str,
        ceiling: Decimal,
        now: datetime | None = None,
    ) -> Reservation | Denial:
        now = now or datetime.now(UTC)
        async with self._sessionmaker() as session, session.begin():
            # One global lock: the month check and the insert are atomic across every worker.
            await session.execute(
                text("SELECT pg_advisory_xact_lock(hashtextextended(:k, 0))"),
                {"k": _GLOBAL_LOCK_KEY},
            )
            month = await _spent(session, month_start(now))
            if month + ceiling > self.month_hard_cap:
                log.warning(
                    "ai budget: monthly hard stop",
                    extra={"capability": capability, "month_spent_usd": str(month)},
                )
                return Denial("monthly_cap")
            if capability == "video" and month + ceiling > self.month_soft_cap:
                return Denial("monthly_cap")
            day = await _spent(session, day_start(now), user_id)
            if capability != "video" and day + ceiling > self.user_daily_cap:
                log.info("ai budget: user daily cap", extra={"capability": capability})
                return Denial("user_daily_cap")
            row = AIUsage(
                user_id=user_id,
                capability=capability,
                model=model,
                status="reserved",
                reserved_usd=ceiling,
                created_at=now,
            )
            session.add(row)
            await session.flush()
            return Reservation(id=row.id, capability=capability, model=model, ceiling=ceiling)

    async def settle(self, reservation: Reservation, meter: UsageMeter, outcome: str) -> None:
        cost = meter.cost
        async with self._sessionmaker() as session, session.begin():
            await session.execute(
                update(AIUsage)
                .where(AIUsage.id == reservation.id)
                .values(
                    status="settled",
                    cost_usd=cost,
                    input_tokens=meter.input_tokens,
                    output_tokens=meter.output_tokens,
                    thinking_tokens=meter.thinking_tokens,
                    attempts=meter.attempts,
                    outcome=outcome[:32],
                    settled_at=datetime.now(UTC),
                )
            )
        if cost > reservation.ceiling:
            # The ceiling is meant to be a true upper bound; say so loudly if it was not.
            log.warning(
                "ai call cost exceeded its reservation",
                extra={"capability": reservation.capability, "model": reservation.model},
            )

    async def status(self, user_id: uuid.UUID | None, now: datetime | None = None) -> BudgetStatus:
        now = now or datetime.now(UTC)
        async with self._sessionmaker() as session:
            month = await _spent(session, month_start(now))
            day = await _spent(session, day_start(now), user_id) if user_id else None
        reason: DenialReason | None = None
        if month + STATUS_HEADROOM_USD > self.month_hard_cap:
            reason = "monthly_cap"
        elif day is not None and day + STATUS_HEADROOM_USD > self.user_daily_cap:
            reason = "user_daily_cap"
        return BudgetStatus(
            month_spent_usd=month,
            user_day_spent_usd=day,
            live=reason is None,
            reason=reason,
            video_extraction_enabled=month < self.month_soft_cap,
        )

    async def video_extraction_enabled(self, now: datetime | None = None) -> bool:
        return (await self.status(None, now)).video_extraction_enabled
