"""Brief 008: the video extraction schema, timestamp handling, the never-invent rules, the
draft pipeline (strip_model_claims on every model string) and the Gemini Files API flow,
replayed from hand-written fixtures in the Gemini REST shape."""

from __future__ import annotations

import json
import uuid
from datetime import UTC, datetime
from decimal import Decimal

import pydantic
import pytest
from google.genai import errors as genai_errors

from app.ai.providers.base import ExtractionRequest
from app.ai.providers.gemini import (
    MAX_ATTEMPTS,
    VIDEO_TOKEN_MARGIN,
    UsageMeter,
    gemini_schema,
    video_input_tokens,
)
from app.ai.video import (
    PARTIAL_UNKNOWN,
    VideoExtractionDraft,
    parse_timestamp,
    salvage_video,
    to_extracted,
)
from app.core.config import Settings
from app.core.errors import AIBlocked, ProviderOutputInvalid, ProviderUnavailable
from app.domains.extraction.pipeline import (
    DEMO_NOTICE,
    build_content,
    clamp_span,
    clean_text,
)
from tests.conftest import TEST_JWT_SECRET
from tests.gemini_fake import FakeTransport, fake_provider, load


def settings() -> Settings:
    return Settings(
        ai_provider="gemini", jwt_secret=TEST_JWT_SECRET, auth_mode="dev", _env_file=None
    )


def fixture_draft(name: str) -> VideoExtractionDraft:
    text = load(name)["response"]["candidates"][0]["content"]["parts"][0]["text"]
    return VideoExtractionDraft.model_validate_json(text)


# --- timestamps ----------------------------------------------------------------------------


@pytest.mark.parametrize(
    "value, expected",
    [
        ("00:00", 0),
        ("01:05", 65_000),
        ("1:05", 65_000),
        ("14:59", 899_000),
        ("123:00", 7_380_000),
        ("1:02:03", 3_723_000),
        ("00:03.5", 3_500),
        ("00:03.25", 3_250),
        (" 00:07 ", 7_000),
        ("00:60", None),
        ("1:60:00", None),
        ("99:99", None),
        ("nonsense", None),
        ("65", None),
        ("", None),
        (None, None),
    ],
)
def test_parse_timestamp(value: str | None, expected: int | None) -> None:
    assert parse_timestamp(value) == expected


@pytest.mark.parametrize(
    "span, duration, expected",
    [
        ((2000, 4000), 10_000, (1000, 5000)),  # padded ±1 s
        ((0, 3000), 10_000, (0, 4000)),  # pad clamps at 0
        ((8000, 20_000), 10_000, (7000, 10_000)),  # end clamped to duration
        ((12_000, 15_000), 10_000, None),  # entirely past the end
        ((3000, 3200), 10_000, None),  # under half a second
        ((None, 3000), 10_000, None),
        ((1000, 2000), 0, None),
    ],
)
def test_clamp_span(span: tuple, duration: int, expected: tuple | None) -> None:
    assert clamp_span(span[0], span[1], duration) == expected


# --- never invent ---------------------------------------------------------------------------


def test_quantities_only_when_shown_or_spoken() -> None:
    extracted = to_extracted(fixture_draft("video_extraction"))
    by_name = {i.name: i for i in extracted.ingredients}
    assert by_name["cooked rice"].quantity == 2 and by_name["cooked rice"].unit == "cup"
    assert by_name["kimchi"].quantity == 1
    # "not_stated" with a number attached: the number is dropped, not trusted.
    assert by_name["sesame oil"].quantity is None and by_name["sesame oil"].unit is None
    assert by_name["sesame oil"].needs_review
    assert by_name["egg"].quantity is None and by_name["egg"].needs_review
    assert [i.id for i in extracted.ingredients] == ["ing-1", "ing-2", "ing-3", "ing-4"]
    assert all(s.evidence_origin == "ai_extracted" for s in extracted.steps)
    assert extracted.steps[0].source_start_ms == 1000 and extracted.steps[0].source_end_ms == 2000
    assert extracted.steps[3].source_start_ms is None


def test_adversarial_output_is_neutralised() -> None:
    extracted = to_extracted(fixture_draft("video_adversarial"))
    a, b, garlic = extracted.ingredients
    assert a.quantity is None  # 900 g "not_stated"
    assert b.quantity == 3  # spoken
    assert garlic.quantity is None  # zero is not an amount
    step0, step1, step2, _step3 = extracted.steps
    assert step0.ingredient_refs == ["ing-1"]  # duplicate model id "a" → first; "zzz" dropped
    assert (step0.source_start_ms, step0.source_end_ms) == (1000, 3500)
    assert step1.source_start_ms is None  # 99:99 / nonsense
    assert step2.source_start_ms is None  # backwards span

    content = build_content(
        extracted, duration_ms=5000, job_id=uuid.uuid4(), source_media_id=None, demo=False
    )
    text = json.dumps(content.model_dump(mode="json"))
    assert "safe to eat" not in text and "safe to serve" not in text
    assert "safe for anyone" not in text and "allergen-free" not in text
    assert "‮" not in text
    steps = content.steps
    assert steps[0].instruction == "Sear the chicken skin side down."
    assert steps[0].success_cues == ["Skin is deep golden"]
    assert steps[0].warnings == []
    assert content.ingredients[1].name == ""  # emptied by the filter: creator fills it in
    assert content.ingredients[2].name == "garlic"
    assert content.summary == "Chicken thighs."
    # Clamped to the 5 s duration and padded.
    assert (steps[0].source_start_ms, steps[0].source_end_ms) == (0, 4500)
    assert (steps[3].source_start_ms, steps[3].source_end_ms) == (2000, 5000)
    assert all(s.evidence_origin == "ai_extracted" for s in steps)
    assert all(i.evidence_origin == "ai_extracted" for i in content.ingredients)
    # Model prose is data: the injected title is kept as text for the creator to edit, never
    # acted on. Publishing still needs the creator.
    assert content.extraction is not None and content.extraction.demo is False


def test_build_content_demo_label_and_title_hint() -> None:
    extracted = to_extracted(fixture_draft("video_extraction"))
    content = build_content(
        extracted,
        duration_ms=4000,
        job_id=uuid.uuid4(),
        source_media_id=uuid.uuid4(),
        demo=True,
        title_hint="  My Rice  ",
    )
    assert content.title == "My Rice"
    assert content.extraction is not None
    assert content.extraction.demo and content.extraction.notice == DEMO_NOTICE
    assert content.extraction.unknowns == ["amount of sesame oil not stated"]


def test_clean_text_strips_controls_and_limits() -> None:
    assert clean_text("a\x00b‮c\nd", 10) == "abc d"
    assert clean_text("x" * 50, 10) == "x" * 10
    assert clean_text("line1\nline2", 50, multiline=True) == "line1\nline2"
    assert clean_text(None, 10) == ""


def test_salvage_keeps_valid_items_only() -> None:
    raw = load("video_partial")["response"]["candidates"][0]["content"]["parts"][0]["text"]
    with pytest.raises(pydantic.ValidationError):
        VideoExtractionDraft.model_validate_json(raw)
    partial = salvage_video(raw)
    assert partial is not None
    assert [i.name for i in partial.ingredients] == ["noodles"]
    assert [s.instruction for s in partial.steps] == ["Boil the noodles."]
    assert partial.title == "Garlic Noodles" and partial.servings is None
    assert partial.unknowns == [PARTIAL_UNKNOWN]
    assert salvage_video("not json") is None
    assert salvage_video('{"ingredients": [], "steps": []}') is None


def test_schema_sent_to_gemini_is_flat() -> None:
    schema = json.dumps(gemini_schema(VideoExtractionDraft))
    assert "$ref" not in schema and "$defs" not in schema
    assert '"quantity_source"' in schema and '"not_stated"' in schema


# --- Gemini video flow (Files API) ----------------------------------------------------------


def request(duration_ms: int = 5000) -> ExtractionRequest:
    return ExtractionRequest(media_ref="/tmp/source.mp4", duration_ms=duration_ms)


def test_video_ceiling_is_duration_based() -> None:
    provider = fake_provider(settings(), FakeTransport())
    assert video_input_tokens(15 * 60 * 1000) == int(900 * 132 * VIDEO_TOKEN_MARGIN)
    short = provider.plan_video(request(10_000))
    long = provider.plan_video(request(15 * 60 * 1000))
    assert long.ceiling_usd > short.ceiling_usd > 0
    # 15 minutes at $0.75 / $3.75: well under a dollar for all attempts, but above the
    # $0.25 per-user day cap (which is why video is left out of it).
    assert Decimal("0.25") < long.ceiling_usd < Decimal("1.00")
    assert long.ceiling_usd == long.attempt_ceiling_usd * MAX_ATTEMPTS


async def test_extract_uploads_waits_generates_deletes() -> None:
    transport = FakeTransport("video_extraction")
    transport.file_states = ["PROCESSING", "ACTIVE"]
    provider = fake_provider(settings(), transport)
    meter = UsageMeter(model="gemini-3.8-flash", at=datetime.now(UTC))
    seen: list[str] = []

    async def on_file(name: str) -> None:
        seen.append(name)

    extracted = await provider.extract(request(), meter, on_file=on_file)
    assert extracted.title == "Weeknight Kimchi Fried Rice"
    assert seen == ["files/fake-1"] and transport.deleted == ["files/fake-1"]
    call = transport.calls[0]
    assert call["config"].media_resolution.value == "MEDIA_RESOLUTION_LOW"
    assert call["config"].response_json_schema is not None
    parts = [c for c in call["contents"] if not isinstance(c, str)]
    assert parts and parts[0].file_data.file_uri.endswith("files/fake-1")
    assert meter.input_tokens == 12000 and meter.output_tokens == 900


async def test_malformed_retries_once_then_salvages() -> None:
    transport = FakeTransport("video_malformed", "video_partial")
    extracted = await fake_provider(settings(), transport).extract(request())
    assert len(transport.calls) == 2
    assert [s.instruction for s in extracted.steps] == ["Boil the noodles."]
    assert PARTIAL_UNKNOWN in extracted.unknowns
    assert transport.deleted == ["files/fake-1"]


async def test_malformed_twice_without_salvage_raises_and_still_deletes() -> None:
    transport = FakeTransport("video_malformed", "video_malformed")
    with pytest.raises(ProviderOutputInvalid):
        await fake_provider(settings(), transport).extract(request())
    assert transport.deleted == ["files/fake-1"]


async def test_blocked_is_not_retried() -> None:
    transport = FakeTransport("blocked_candidate")
    with pytest.raises(AIBlocked):
        await fake_provider(settings(), transport).extract(request())
    assert len(transport.calls) == 1 and transport.deleted == ["files/fake-1"]


async def test_file_processing_failure() -> None:
    transport = FakeTransport()
    transport.file_states = ["FAILED"]
    with pytest.raises(ProviderUnavailable):
        await fake_provider(settings(), transport).extract(request())
    assert transport.calls == [] and transport.deleted == ["files/fake-1"]


async def test_file_never_active_times_out() -> None:
    transport = FakeTransport()
    transport.file_states = ["PROCESSING"] * 10_000
    clock = iter(range(0, 10_000_000, 30))
    provider = fake_provider(settings(), transport)
    provider._clock = lambda: float(next(clock))  # type: ignore[method-assign]
    with pytest.raises(ProviderUnavailable, match="too long"):
        await provider.extract(request())
    assert transport.deleted == ["files/fake-1"]


async def test_upload_error_is_unavailable() -> None:
    transport = FakeTransport()
    transport.upload_error = genai_errors.ServerError(503, {"error": {"message": "x"}})
    with pytest.raises(ProviderUnavailable):
        await fake_provider(settings(), transport).extract(request())
    assert transport.deleted == []
