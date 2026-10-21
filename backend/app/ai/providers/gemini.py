"""GeminiProvider stub. Real adapters land in Slice 4+ behind the same Protocols.

Every method raises ``ProviderNotConfigured`` so a misconfigured deployment fails loudly instead
of silently falling back to fabricated output.
"""

from __future__ import annotations

from typing import Any

from app.ai.providers.base import (
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
from app.core.config import Settings
from app.core.errors import ProviderNotConfigured


class GeminiProvider:
    name = "gemini"

    def __init__(self, settings: Settings) -> None:
        self._configured = bool(settings.gemini_api_key)
        self._model_structured = settings.gemini_model_structured
        self._model_live = settings.gemini_model_live

    def describe(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "configured": self._configured,
            "model_structured": self._model_structured,
            "model_live": self._model_live,
        }

    def _unavailable(self, capability: str) -> ProviderNotConfigured:
        return ProviderNotConfigured(
            f"Gemini {capability} is not available yet (Slice 4+). Set AI_PROVIDER=mock."
        )

    async def extract(self, request: ExtractionRequest) -> ExtractedRecipeDraft:
        raise self._unavailable("recipe extraction")

    async def observe(self, request: PantryObservationRequest) -> PantryObservation:
        raise self._unavailable("pantry observation")

    async def suggest(self, request: SubstitutionRequest) -> SubstitutionResponse:
        raise self._unavailable("substitution advice")

    async def answer(self, request: CoachRequest) -> CoachResponse:
        raise self._unavailable("cooking coach")

    async def inspect(self, request: InspectRequest) -> InspectResponse:
        raise self._unavailable("visual inspection")
