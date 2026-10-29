"""Opt-in live smoke against the real Gemini API (brief 007): ``make ai-live-smoke``.

Skipped unless ``SOUSLENS_LIVE_SMOKE=1`` **and** ``GEMINI_API_KEY`` are set, so a key in the
environment never makes ``make check`` spend money. Three small calls (coach, pantry
transcript on the lite model, inspect with a 32x32 generated image) are metered with the same
``UsageMeter`` the cost guard uses; the run fails if they cost $0.05 or more.
``GEMINI_RECORD=1`` also writes each live response to ``tests/fixtures/gemini/recorded/``.
"""

from __future__ import annotations

import json
import os
import struct
import zlib
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

import pytest
from google.genai import types

from app.ai.budget import UsageMeter
from app.ai.providers.base import (
    CoachRequest,
    InspectRequest,
    PantryObservationRequest,
    StepSummary,
)
from app.ai.providers.gemini import GeminiProvider, GenAITransport
from app.core.config import Settings
from tests.conftest import TEST_JWT_SECRET

LIVE = os.environ.get("SOUSLENS_LIVE_SMOKE") == "1" and bool(os.environ.get("GEMINI_API_KEY"))
pytestmark = pytest.mark.skipif(
    not LIVE, reason="live smoke: set SOUSLENS_LIVE_SMOKE=1 and GEMINI_API_KEY (make ai-live-smoke)"
)
BUDGET_USD = Decimal("0.05")
RECORD_DIR = Path(__file__).resolve().parents[1] / "fixtures" / "gemini" / "recorded"


def tiny_png(rgb: tuple[int, int, int] = (200, 170, 90), size: int = 32) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    row = b"\x00" + bytes(rgb) * size
    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(row * size))
        + chunk(b"IEND", b"")
    )


class RecordingTransport(GenAITransport):
    def __init__(self, api_key: str) -> None:
        super().__init__(api_key)
        self.n = 0

    async def generate(
        self, *, model: str, contents: list[Any], config: types.GenerateContentConfig
    ) -> types.GenerateContentResponse:
        response = await super().generate(model=model, contents=contents, config=config)
        if os.environ.get("GEMINI_RECORD") == "1":
            RECORD_DIR.mkdir(parents=True, exist_ok=True)
            self.n += 1
            body = response.model_dump(mode="json", by_alias=True, exclude_none=True)
            body.pop("sdkHttpResponse", None)
            (RECORD_DIR / f"live_{self.n:02d}_{model}.json").write_text(
                json.dumps({"response": body}, indent=2, ensure_ascii=False) + "\n"
            )
        return response


@pytest.fixture(scope="module")
def live() -> GeminiProvider:
    key = os.environ["GEMINI_API_KEY"]
    settings = Settings(
        ai_provider="gemini",
        gemini_api_key=key,
        jwt_secret=TEST_JWT_SECRET,
        auth_mode="dev",
        environment="test",
    )
    return GeminiProvider(settings, transport=RecordingTransport(key))


STEP = StepSummary(
    id="step-1",
    order=0,
    instruction="Slice the onion thinly, about 3 mm, and soften it in the oil over medium heat.",
    success_cues=["Onion is soft and translucent"],
)


async def test_live_smoke_under_five_cents(live: GeminiProvider) -> None:
    meters: list[UsageMeter] = []

    def meter(model: str) -> UsageMeter:
        m = UsageMeter(model=model, at=datetime.now(UTC))
        meters.append(m)
        return m

    coach = await live.answer(
        CoachRequest(
            recipe_id="r",
            recipe_version_id="v",
            version_number=1,
            title="Weeknight Onion Pasta",
            servings=2,
            current_step=STEP,
            session_revision=3,
            query="how thin should I slice the onion?",
        ),
        meter("gemini-3.8-flash"),
    )
    assert coach.answer_text and coach.grounded_session_revision == 3

    pantry = await live.observe(
        PantryObservationRequest(mode="transcript", transcript="I have two onions and some rice"),
        meter("gemini-3.5-flash-lite"),
    )
    assert pantry.requires_confirmation is True

    look = await live.inspect(
        InspectRequest(
            session_id="s",
            grounded_revision=3,
            query="does this look translucent yet?",
            image_ref="inline",
            mime_type="image/png",
            current_step=STEP,
            image_bytes=tiny_png(),
        ),
        meter("gemini-3.8-flash"),
    )
    assert look.food_safety_certified is False

    total = sum((m.cost for m in meters), Decimal(0))
    print(f"live smoke cost: ${total:.5f} over {sum(m.attempts for m in meters)} attempts")
    assert total < BUDGET_USD
