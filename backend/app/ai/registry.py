"""Pick the AI provider from ``AI_PROVIDER``. Business code only ever sees the Protocols."""

from __future__ import annotations

from app.ai.providers.base import AIProvider
from app.ai.providers.gemini import GeminiProvider
from app.ai.providers.mock import MockAIProvider
from app.core.config import Settings


def build_provider(settings: Settings) -> AIProvider:
    match settings.ai_provider:
        case "mock":
            return MockAIProvider(settings.fixtures_dir)
        case "gemini":
            return GeminiProvider(settings)
    raise ValueError(f"Unknown AI_PROVIDER {settings.ai_provider!r}")  # pragma: no cover
