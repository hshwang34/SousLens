"""Per-request, per-user budgeted provider (brief 007 cost guard).

``GuardedProvider`` implements every AI Protocol. Each call reserves the Gemini call's
worst-case ceiling for this user, runs it with a ``UsageMeter`` and settles the ledger from the
reported usage, whatever happens (success, block, error, timeout, cancellation). When a cap
refuses the reservation it answers from the labelled ``MockAIProvider`` path instead and sets
``notice``; the endpoints copy it onto the response so the app can show "AI is resting — demo
answers for now". Under ``AI_PROVIDER=mock`` none of this exists: endpoints get the plain mock.
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime
from typing import Any, TypeVar

from fastapi import Request

from app.ai.budget import Capability, CostGuard, Denial, UsageMeter
from app.ai.notice import AINotice
from app.ai.providers.base import (
    AIProvider,
    CoachRequest,
    CoachResponse,
    ExtractedRecipeDraft,
    ExtractionRequest,
    InspectRequest,
    InspectResponse,
    PantryObservation,
    PantryObservationRequest,
    SubstitutionRequest,
    SubstitutionResponse,
)
from app.ai.providers.gemini import GeminiProvider
from app.ai.providers.mock import MockAIProvider
from app.core.errors import AIBlocked, ProviderOutputInvalid

log = logging.getLogger("souslens.ai.guard")

T = TypeVar("T")

RESTING_PHOTO_NOTE = "AI is resting, so this photo wasn't read. Type or say your items instead."


class GuardedProvider:
    name = "gemini"

    def __init__(
        self,
        real: GeminiProvider,
        fallback: MockAIProvider,
        guard: CostGuard,
        user_id: uuid.UUID,
    ) -> None:
        self._real = real
        self._fallback = fallback
        self._guard = guard
        self._user_id = user_id
        self.notice: AINotice | None = None

    @property
    def answered_by(self) -> str:
        """Who produced the last answer: the demo path once a cap refused the call."""
        return "mock" if self.notice is not None else self.name

    def describe(self) -> dict[str, Any]:
        return {**self._real.describe(), "guarded": True}

    async def _run(
        self,
        capability: Capability,
        request: Any,
        live: Callable[[UsageMeter], Awaitable[T]],
        demo: Callable[[], Awaitable[T]],
    ) -> T:
        if not self._real.configured:
            raise self._real.unavailable(capability)
        plan = self._real.plan_for(capability, request)
        decision = await self._guard.reserve(
            self._user_id, capability, plan.model, plan.ceiling_usd
        )
        if isinstance(decision, Denial):
            self.notice = AINotice(reason=decision.reason)
            log.info(
                "ai fallback to demo answers",
                extra={"capability": capability, "reason": decision.reason},
            )
            return await demo()
        meter = UsageMeter(model=plan.model, at=datetime.now(UTC))
        outcome = "cancelled"
        try:
            result = await live(meter)
            outcome = "ok"
            return result
        except AIBlocked:
            outcome = "blocked"
            raise
        except ProviderOutputInvalid:
            outcome = "malformed"
            raise
        except Exception:
            outcome = "error"
            raise
        finally:
            # Shielded: an outer timeout cancelling this call must not lose the ledger entry.
            await asyncio.shield(self._guard.settle(decision, meter, outcome))

    # RecipeExtractor (brief 008 wires the video budget; refused here until then)
    async def extract(self, request: ExtractionRequest) -> ExtractedRecipeDraft:
        return await self._real.extract(request)

    async def observe(self, request: PantryObservationRequest) -> PantryObservation:
        capability: Capability = "pantry_photo" if request.mode == "photo" else "pantry_transcript"

        async def demo() -> PantryObservation:
            if request.mode == "photo":
                # Never show fixture items for a real photo: that would invent pantry contents.
                return PantryObservation(
                    mode="photo",
                    candidates=[],
                    notes=[RESTING_PHOTO_NOTE],
                    unknowns=["what is in this photo (AI is resting)"],
                )
            return await self._fallback.observe(request)

        return await self._run(capability, request, lambda m: self._real.observe(request, m), demo)

    async def suggest(self, request: SubstitutionRequest) -> SubstitutionResponse:
        return await self._run(
            "substitution",
            request,
            lambda m: self._real.suggest(request, m),
            lambda: self._fallback.suggest(request),
        )

    async def answer(self, request: CoachRequest) -> CoachResponse:
        return await self._run(
            "coach",
            request,
            lambda m: self._real.answer(request, m),
            lambda: self._fallback.answer(request),
        )

    async def inspect(self, request: InspectRequest) -> InspectResponse:
        return await self._run(
            "inspect",
            request,
            lambda m: self._real.inspect(request, m),
            lambda: self._fallback.inspect(request),
        )


def provider_for(request: Request, user_id: uuid.UUID) -> AIProvider | GuardedProvider:
    """The provider an endpoint should use for this user. Mock mode: the shared mock, as is."""
    base = request.app.state.ai_provider
    if isinstance(base, GeminiProvider):
        guard: CostGuard = request.app.state.cost_guard
        return GuardedProvider(base, request.app.state.ai_fallback, guard, user_id)
    return base


def notice_of(provider: object) -> AINotice | None:
    return provider.notice if isinstance(provider, GuardedProvider) else None
