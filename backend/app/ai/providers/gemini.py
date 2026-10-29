"""GeminiProvider: the real coach, pantry, substitution and visual-observer adapters (brief 007).

* ``google-genai`` async client, structured output (``response_mime_type=application/json`` +
  ``response_json_schema``). The schema sent to Gemini is derived from a model-facing *draft*
  model (refs inlined, ``const`` → ``enum``); the answer is then validated strictly with
  Pydantic and mapped onto the shared contracts. Fields the backend owns (revisions,
  ``food_safety_certified``, ``requires_confirmation``, ``recommended_step_change``) are never
  taken from the model.
* Per-capability models from settings (DECISIONS #19); explicit safety settings at
  ``BLOCK_MEDIUM_AND_ABOVE``; ``max_output_tokens`` on every call; low thinking.
* Bounded retries inside one whole-call deadline (``GEMINI_TIMEOUT_SECONDS``): at most 3
  attempts. 429 / 5xx / timeouts retry with jittered backoff; malformed or truncated JSON
  retries once; a 4xx is never retried; a safety block raises ``AIBlocked`` and is never retried
  into made-up output.
* Every attempt's ``usage_metadata`` goes into the caller's ``UsageMeter``; an attempt whose
  cost is unknown (timeout, cancellation) is metered at its worst case.
* Images are passed as inline bytes for the one call and never stored or logged. Logs carry
  capability, model, status codes and token counts only, never prompts, answers or the key.
* Video (brief 008): Files API upload → poll until ``ACTIVE`` (bounded) → structured generate at
  ``MEDIA_RESOLUTION_LOW`` → the file is deleted whatever happened. The reservation ceiling is
  duration based (~100 tok/s video + 32 tok/s audio, plus a margin).
"""

from __future__ import annotations

import asyncio
import copy
import json
import logging
import math
import random
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from typing import Any, Literal, Protocol, TypeVar

import httpx
import pydantic
from google.genai import errors as genai_errors
from google.genai import types
from pydantic import BaseModel, Field

from app.ai.budget import Capability, UsageMeter
from app.ai.pricing import price_for
from app.ai.prompts import (
    COACH_SYSTEM,
    INSPECT_SYSTEM,
    PANTRY_SYSTEM,
    SUBSTITUTION_SYSTEM,
    VIDEO_SYSTEM,
    data_block,
)
from app.ai.providers.base import (
    CoachRequest,
    CoachResponse,
    ExtractedRecipeDraft,
    ExtractionRequest,
    GroundingRef,
    InspectRequest,
    InspectResponse,
    PantryCandidate,
    PantryObservation,
    PantryObservationRequest,
    ProposedAction,
    StrictModel,
    SubstitutionKind,
    SubstitutionRequest,
    SubstitutionResponse,
    SubstitutionSuggestion,
    UncertaintyLevel,
)
from app.ai.video import VideoExtractionDraft, salvage_video, to_extracted
from app.core.config import Settings
from app.core.errors import (
    AIBlocked,
    ProviderNotConfigured,
    ProviderOutputInvalid,
    ProviderUnavailable,
)

log = logging.getLogger("souslens.ai.gemini")

MAX_ATTEMPTS = 3  # the first call plus at most two retries, whatever the cause
MAX_MALFORMED_RETRIES = 1
BACKOFF_BASE_SECONDS = 0.5
MIN_ATTEMPT_SECONDS = 2.0  # don't start an attempt with less time than this left
THINKING_ALLOWANCE_TOKENS = 4096  # ceiling only: covers thinking whether or not it counts in max
IMAGE_INPUT_TOKENS_CEILING = 3000  # one photo; Gemini 3 bills ~1.1k at high resolution
MAX_OUTPUT_TOKENS: dict[str, int] = {
    "coach": 2048,
    "inspect": 2048,
    "pantry_photo": 3072,
    "pantry_transcript": 3072,
    "substitution": 3072,
    "video": 16384,
}
# Video input estimate (brief 008): Gemini bills ~70 tokens per frame at 1 fps with
# MEDIA_RESOLUTION_LOW plus 32 tokens/s of audio; 100 tok/s of video is a deliberate over-estimate,
# and the margin covers rounding and container overhead. Settlement uses the real usage.
VIDEO_TOKENS_PER_SECOND = 100
AUDIO_TOKENS_PER_SECOND = 32
VIDEO_TOKEN_MARGIN = 1.25
FILE_POLL_SECONDS = 2.0
_BLOCK_FINISH = {"SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "IMAGE_SAFETY", "RECITATION"}
_SAFETY_CATEGORIES = (
    types.HarmCategory.HARM_CATEGORY_HARASSMENT,
    types.HarmCategory.HARM_CATEGORY_HATE_SPEECH,
    types.HarmCategory.HARM_CATEGORY_SEXUALLY_EXPLICIT,
    types.HarmCategory.HARM_CATEGORY_DANGEROUS_CONTENT,
)
SAFETY_SETTINGS = [
    types.SafetySetting(category=c, threshold=types.HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE)
    for c in _SAFETY_CATEGORIES
]

D = TypeVar("D", bound=BaseModel)


# --- Model-facing drafts (what Gemini fills in) --------------------------------------------


class CoachDraft(StrictModel):
    answer_text: str = Field(min_length=1, max_length=1200)
    grounding: list[GroundingRef] = Field(default_factory=list, max_length=8)
    uncertainty: UncertaintyLevel = "medium"
    safety_notice: str | None = Field(default=None, max_length=400)
    proposed_action: ProposedAction | None = None


class InspectDraft(StrictModel):
    observation: str = Field(min_length=1, max_length=800)
    step_alignment: str = Field(max_length=600)
    confidence: UncertaintyLevel
    limitations: list[str] = Field(default_factory=list, max_length=6)
    suggested_action: str | None = Field(default=None, max_length=400)


class PantryCandidateDraft(StrictModel):
    raw_label: str = Field(min_length=1, max_length=120)
    canonical_name: str | None = Field(default=None, max_length=80)
    quantity: float | None = Field(default=None, ge=0)
    unit: str | None = Field(default=None, max_length=16)
    confidence: float = Field(ge=0.0, le=1.0)
    evidence: str = Field(max_length=300)
    quantity_is_estimate: bool = False


class PantryDraft(StrictModel):
    candidates: list[PantryCandidateDraft] = Field(default_factory=list, max_length=40)
    notes: list[str] = Field(default_factory=list, max_length=8)
    unknowns: list[str] = Field(default_factory=list, max_length=20)


class SubstitutionSuggestionDraft(StrictModel):
    candidate: str = Field(min_length=1, max_length=120)
    kind: SubstitutionKind
    ratio_or_amount: str = Field(max_length=120)
    rationale: str = Field(max_length=400)
    impact_flavor: str = Field(max_length=200)
    impact_texture: str = Field(max_length=200)
    adjusted_steps: list[str] = Field(default_factory=list, max_length=6)
    confidence: float = Field(ge=0.0, le=1.0)
    risks: list[str] = Field(default_factory=list, max_length=6)


class SubstitutionDraft(StrictModel):
    suggestions: list[SubstitutionSuggestionDraft] = Field(default_factory=list, max_length=3)
    cannot_substitute: bool = False
    reason: str | None = Field(default=None, max_length=400)


# --- Schema derivation ---------------------------------------------------------------------

_DROP_KEYS = {"title", "default", "examples"}


def gemini_schema(model: type[BaseModel]) -> dict[str, Any]:
    """A JSON Schema Gemini's structured-output subset accepts: ``$defs``/``$ref`` inlined,
    ``const`` → one-value ``enum``, ``anyOf [X, null]`` → ``type: [X, "null"]``, titles and
    defaults dropped. Strict validation still happens in Pydantic afterwards."""
    raw = model.model_json_schema()
    defs = raw.pop("$defs", {})

    def walk(node: Any) -> Any:
        if isinstance(node, list):
            return [walk(n) for n in node]
        if not isinstance(node, dict):
            return node
        if "$ref" in node:
            name = node["$ref"].rsplit("/", 1)[-1]
            merged = {**copy.deepcopy(defs[name]), **{k: v for k, v in node.items() if k != "$ref"}}
            return walk(merged)
        out: dict[str, Any] = {}
        for key, value in node.items():
            if key in _DROP_KEYS:
                continue
            if key == "const":
                out["enum"] = [value]
                continue
            out[key] = walk(value)
        any_of = out.get("anyOf")
        if isinstance(any_of, list) and len(any_of) == 2 and {"type": "null"} in any_of:
            other = next(a for a in any_of if a != {"type": "null"})
            if isinstance(other.get("type"), str):
                out.pop("anyOf")
                merged = {**other, "type": [other["type"], "null"]}
                if "enum" in merged:
                    merged["enum"] = [*merged["enum"], None]
                out = {**merged, **out}
        return out

    return walk(raw)


# --- Transport -----------------------------------------------------------------------------


class GeminiTransport(Protocol):
    async def generate(
        self, *, model: str, contents: list[Any], config: types.GenerateContentConfig
    ) -> types.GenerateContentResponse: ...


class GeminiFileTransport(Protocol):
    """The Files API surface the video extractor needs (brief 008)."""

    async def upload_file(self, *, path: str, mime_type: str) -> types.File: ...

    async def get_file(self, *, name: str) -> types.File: ...

    async def delete_file(self, *, name: str) -> None: ...


class GenAITransport:
    """The real ``google-genai`` async client. SDK-level retries are off; ours are bounded."""

    def __init__(self, api_key: str) -> None:
        from google import genai

        self._client = genai.Client(
            api_key=api_key,
            http_options=types.HttpOptions(retry_options=types.HttpRetryOptions(attempts=1)),
        )

    async def generate(
        self, *, model: str, contents: list[Any], config: types.GenerateContentConfig
    ) -> types.GenerateContentResponse:
        return await self._client.aio.models.generate_content(
            model=model, contents=contents, config=config
        )

    async def upload_file(self, *, path: str, mime_type: str) -> types.File:
        return await self._client.aio.files.upload(
            file=path, config=types.UploadFileConfig(mime_type=mime_type)
        )

    async def get_file(self, *, name: str) -> types.File:
        return await self._client.aio.files.get(name=name)

    async def delete_file(self, *, name: str) -> None:
        await self._client.aio.files.delete(name=name)


# --- Call plans ----------------------------------------------------------------------------


@dataclass(frozen=True)
class CallPlan:
    capability: Capability
    model: str
    system: str
    contents: list[Any]
    schema: dict[str, Any]
    max_output_tokens: int
    attempt_ceiling_usd: Decimal
    media_resolution: types.MediaResolution | None = None

    @property
    def ceiling_usd(self) -> Decimal:
        return self.attempt_ceiling_usd * MAX_ATTEMPTS


class _Malformed(Exception):
    pass


class _Transient(Exception):
    pass


def estimate_input_tokens(system: str, contents: list[Any], schema: dict[str, Any]) -> int:
    """Over-estimate: 1 token per 2 UTF-8 bytes (real text is ~4) of the system instruction,
    the text parts and the response schema (it is sent as input too), plus a photo ceiling."""
    total = len(system.encode("utf-8")) + len(json.dumps(schema).encode("utf-8"))
    images = 0
    for part in contents:
        if isinstance(part, str):
            total += len(part.encode("utf-8"))
        else:
            images += 1
    return total // 2 + 256 + images * IMAGE_INPUT_TOKENS_CEILING


def video_input_tokens(duration_ms: int) -> int:
    seconds = math.ceil(max(duration_ms, 0) / 1000)
    per_second = VIDEO_TOKENS_PER_SECOND + AUDIO_TOKENS_PER_SECOND
    return math.ceil(seconds * per_second * VIDEO_TOKEN_MARGIN)


def _attempt_ceiling(model: str, input_tokens: int, max_output: int) -> Decimal:
    price = price_for(model, datetime.now(UTC))
    return (
        Decimal(input_tokens) * price.input_per_m
        + Decimal(max_output + THINKING_ALLOWANCE_TOKENS) * price.output_per_m
    ) / Decimal(1_000_000)


def _blocked(response: types.GenerateContentResponse) -> bool:
    feedback = response.prompt_feedback
    if feedback is not None and feedback.block_reason is not None:
        return True
    for cand in response.candidates or []:
        reason = cand.finish_reason
        name = getattr(reason, "value", reason)
        if name in _BLOCK_FINISH:
            return True
    return False


def _text(response: types.GenerateContentResponse) -> str:
    cands = response.candidates or []
    if not cands:
        raise _Malformed("no candidates")
    reason = cands[0].finish_reason
    if getattr(reason, "value", reason) == "MAX_TOKENS":
        raise _Malformed("truncated")
    parts = (cands[0].content.parts if cands[0].content else None) or []
    text = "".join(p.text for p in parts if p.text and not p.thought)
    if not text.strip():
        raise _Malformed("empty")
    return text


class GeminiProvider:
    name = "gemini"

    def __init__(
        self,
        settings: Settings,
        transport: GeminiTransport | None = None,
        *,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        key = settings.gemini_api_key.get_secret_value() if settings.gemini_api_key else ""
        self._configured = transport is not None or bool(key)
        self._transport: GeminiTransport | None = transport
        if self._transport is None and key:
            self._transport = GenAITransport(key)
        self._models: dict[str, str] = {
            "coach": settings.gemini_model_coach,
            "inspect": settings.gemini_model_inspect,
            "pantry_photo": settings.gemini_model_pantry,
            "pantry_transcript": settings.gemini_model_pantry,
            "substitution": settings.gemini_model_substitution,
            "video": settings.gemini_model_video,
        }
        self._deadline_seconds = settings.gemini_timeout_seconds
        self._video_deadline_seconds = settings.gemini_video_timeout_seconds
        self._file_active_timeout = settings.gemini_file_active_timeout_seconds
        self._sleep = sleep
        self._clock = clock

    @property
    def configured(self) -> bool:
        return self._configured

    def describe(self) -> dict[str, Any]:
        return {"name": self.name, "configured": self._configured, "models": dict(self._models)}

    def unavailable(self, capability: str) -> ProviderNotConfigured:
        return ProviderNotConfigured(
            f"Gemini {capability} is not configured. Set GEMINI_API_KEY or AI_PROVIDER=mock."
        )

    # --- plans ---------------------------------------------------------------------------

    def _plan(
        self,
        capability: Capability,
        system: str,
        contents: list[Any],
        draft: type[BaseModel],
    ) -> CallPlan:
        model = self._models[capability]
        max_out = MAX_OUTPUT_TOKENS[capability]
        schema = gemini_schema(draft)
        return CallPlan(
            capability=capability,
            model=model,
            system=system,
            contents=contents,
            schema=schema,
            max_output_tokens=max_out,
            attempt_ceiling_usd=_attempt_ceiling(
                model, estimate_input_tokens(system, contents, schema), max_out
            ),
        )

    def plan_coach(self, request: CoachRequest) -> CallPlan:
        packet = request.model_dump(mode="json", exclude={"query"})
        contents = [
            "Answer the user's question about the recipe they are cooking right now.",
            data_block("recipe_data", packet),
            data_block("user_question", {"question": request.query}),
        ]
        return self._plan("coach", COACH_SYSTEM, contents, CoachDraft)

    def plan_inspect(self, request: InspectRequest) -> CallPlan:
        step = request.current_step.model_dump(mode="json")
        contents: list[Any] = [
            "Look at the attached photo of the current step and answer the user's question.",
            data_block(
                "step_data",
                {
                    "recipe_title": request.recipe_title,
                    "ingredients": request.ingredient_names,
                    "current_step": step,
                },
            ),
            data_block("user_question", {"question": request.query}),
        ]
        if request.image_bytes:
            contents.append(
                types.Part.from_bytes(data=request.image_bytes, mime_type=request.mime_type)
            )
        return self._plan("inspect", INSPECT_SYSTEM, contents, InspectDraft)

    def plan_observe(self, request: PantryObservationRequest) -> CallPlan:
        if request.mode == "photo":
            contents: list[Any] = ["List candidate pantry items visible in the attached photo."]
            if request.image_bytes:
                contents.append(
                    types.Part.from_bytes(
                        data=request.image_bytes, mime_type=request.image_mime_type or "image/jpeg"
                    )
                )
            return self._plan("pantry_photo", PANTRY_SYSTEM, contents, PantryDraft)
        contents = [
            "List candidate pantry items the user said in this transcript.",
            data_block("pantry_data", {"transcript": request.transcript or ""}),
        ]
        return self._plan("pantry_transcript", PANTRY_SYSTEM, contents, PantryDraft)

    def plan_suggest(self, request: SubstitutionRequest) -> CallPlan:
        contents = [
            "Suggest substitutions for the missing ingredient.",
            data_block("request_data", request.model_dump(mode="json")),
        ]
        return self._plan("substitution", SUBSTITUTION_SYSTEM, contents, SubstitutionDraft)

    def plan_video(self, request: ExtractionRequest, file: types.File | None = None) -> CallPlan:
        contents: list[Any] = [
            "Extract a draft recipe from the attached cooking video.",
            data_block(
                "creator_data",
                {"title_hint": request.title_hint, "creator_notes": request.creator_notes},
            ),
        ]
        if file is not None and file.uri:
            contents.append(
                types.Part.from_uri(
                    file_uri=file.uri, mime_type=file.mime_type or request.mime_type
                )
            )
        model = self._models["video"]
        max_out = MAX_OUTPUT_TOKENS["video"]
        schema = gemini_schema(VideoExtractionDraft)
        text_tokens = estimate_input_tokens(VIDEO_SYSTEM, contents[:2], schema)
        media_tokens = video_input_tokens(request.duration_ms or 0)
        return CallPlan(
            capability="video",
            model=model,
            system=VIDEO_SYSTEM,
            contents=contents,
            schema=schema,
            max_output_tokens=max_out,
            attempt_ceiling_usd=_attempt_ceiling(model, text_tokens + media_tokens, max_out),
            media_resolution=types.MediaResolution.MEDIA_RESOLUTION_LOW,
        )

    def plan_for(self, capability: Capability, request: Any) -> CallPlan:
        match capability:
            case "video":
                return self.plan_video(request)
            case "coach":
                return self.plan_coach(request)
            case "inspect":
                return self.plan_inspect(request)
            case "pantry_photo" | "pantry_transcript":
                return self.plan_observe(request)
            case "substitution":
                return self.plan_suggest(request)
        raise ValueError(capability)  # pragma: no cover

    # --- the call loop -------------------------------------------------------------------

    def _config(self, plan: CallPlan, timeout_s: float) -> types.GenerateContentConfig:
        return types.GenerateContentConfig(
            media_resolution=plan.media_resolution,
            system_instruction=plan.system,
            response_mime_type="application/json",
            response_json_schema=plan.schema,
            max_output_tokens=plan.max_output_tokens,
            safety_settings=SAFETY_SETTINGS,
            thinking_config=types.ThinkingConfig(thinking_level=types.ThinkingLevel.LOW),
            http_options=types.HttpOptions(timeout=max(int(timeout_s * 1000), 1000)),
            automatic_function_calling=types.AutomaticFunctionCallingConfig(disable=True),
        )

    async def run(
        self,
        plan: CallPlan,
        draft: type[D],
        meter: UsageMeter | None = None,
        *,
        salvage: Callable[[str], D | None] | None = None,
        deadline_seconds: float | None = None,
    ) -> D:
        if self._transport is None:
            raise self.unavailable(plan.capability)
        meter = meter or UsageMeter(model=plan.model, at=datetime.now(UTC))
        deadline = self._clock() + (deadline_seconds or self._deadline_seconds)
        malformed = 0
        transient = 0
        last_text: str | None = None
        for attempt in range(1, MAX_ATTEMPTS + 1):
            remaining = deadline - self._clock()
            if attempt > 1 and remaining < MIN_ATTEMPT_SECONDS:
                break
            meter.attempts += 1
            try:
                response = await self._attempt(plan, meter, remaining)
                if _blocked(response):
                    log.info(
                        "gemini blocked", extra={"capability": plan.capability, "model": plan.model}
                    )
                    raise AIBlocked(
                        "The assistant can't help with that one. The step is shown as written."
                    )
                last_text = _text(response)
                return draft.model_validate_json(last_text)
            except _Transient:
                transient += 1
            except (_Malformed, pydantic.ValidationError) as exc:
                malformed += 1
                log.info(
                    "gemini malformed output",
                    extra={"capability": plan.capability, "error_type": type(exc).__name__},
                )
                if malformed > MAX_MALFORMED_RETRIES:
                    break
            if attempt < MAX_ATTEMPTS:
                delay = BACKOFF_BASE_SECONDS * (2 ** (attempt - 1)) * random.uniform(0.5, 1.5)
                delay = min(delay, max(deadline - self._clock() - MIN_ATTEMPT_SECONDS, 0))
                if delay > 0:
                    await self._sleep(delay)
        if malformed:
            if salvage is not None and last_text is not None:
                partial = salvage(last_text)
                if partial is not None:
                    return partial
            raise ProviderOutputInvalid(
                "The assistant's answer came back malformed; the step text is unchanged"
            )
        raise ProviderUnavailable("The assistant is unavailable right now; try again")

    async def _attempt(
        self, plan: CallPlan, meter: UsageMeter, remaining: float
    ) -> types.GenerateContentResponse:
        assert self._transport is not None
        timeout_s = max(remaining, MIN_ATTEMPT_SECONDS)
        got_answer = False
        try:
            response = await asyncio.wait_for(
                self._transport.generate(
                    model=plan.model, contents=plan.contents, config=self._config(plan, timeout_s)
                ),
                timeout=timeout_s,
            )
            got_answer = True
        except genai_errors.APIError as exc:
            got_answer = True  # an error answer is not billed
            code = int(getattr(exc, "code", 0) or 0)
            log.warning(
                "gemini api error", extra={"capability": plan.capability, "status_code": code}
            )
            if code == 429 or code >= 500:
                raise _Transient from exc
            raise ProviderUnavailable("The assistant could not answer that request") from exc
        except TimeoutError as exc:
            log.warning("gemini timeout", extra={"capability": plan.capability})
            raise _Transient from exc
        except (OSError, httpx.HTTPError) as exc:
            log.warning(
                "gemini network error",
                extra={"capability": plan.capability, "error_type": type(exc).__name__},
            )
            raise _Transient from exc
        finally:
            if not got_answer:
                # Timed out, cancelled or cut off: Google may still bill it, so assume the worst.
                meter.record_unknown(plan.attempt_ceiling_usd)
        meter.record(response.usage_metadata)
        log.info(
            "gemini call",
            extra={
                "capability": plan.capability,
                "model": plan.model,
                "input_tokens": meter.input_tokens,
                "output_tokens": meter.output_tokens,
                "thinking_tokens": meter.thinking_tokens,
            },
        )
        return response

    # --- Protocol methods ----------------------------------------------------------------

    async def extract(
        self,
        request: ExtractionRequest,
        meter: UsageMeter | None = None,
        *,
        on_file: Callable[[str], Awaitable[None]] | None = None,
    ) -> ExtractedRecipeDraft:
        """``request.media_ref`` is a local file path (the worker's download of the source).
        ``on_file`` is told the Files API name right after upload, so a crashed worker's
        successor can delete a file this attempt never got to clean up."""
        transport = self._transport
        if transport is None:
            raise self.unavailable("video extraction")
        if not all(hasattr(transport, m) for m in ("upload_file", "get_file", "delete_file")):
            raise self.unavailable("video extraction")
        files: GeminiFileTransport = transport  # type: ignore[assignment]
        try:
            uploaded = await files.upload_file(path=request.media_ref, mime_type=request.mime_type)
        except genai_errors.APIError as exc:
            log.warning("gemini file upload failed", extra={"status_code": exc.code})
            raise ProviderUnavailable("The video couldn't be sent to the AI; try again") from exc
        name = uploaded.name or ""
        try:
            if on_file is not None and name:
                await on_file(name)
            active = await self._wait_active(files, uploaded)
            plan = self.plan_video(request, active)
            draft = await self.run(
                plan,
                VideoExtractionDraft,
                meter,
                salvage=salvage_video,
                deadline_seconds=self._video_deadline_seconds,
            )
        finally:
            if name:
                await self.delete_file(name)
        return to_extracted(draft)

    async def _wait_active(self, files: GeminiFileTransport, file: types.File) -> types.File:
        deadline = self._clock() + self._file_active_timeout
        current = file
        while True:
            state = getattr(current.state, "value", current.state)
            if state == "ACTIVE":
                return current
            if state == "FAILED":
                raise ProviderUnavailable("The AI couldn't process this video")
            if self._clock() >= deadline:
                raise ProviderUnavailable("The AI took too long to process this video; try again")
            await self._sleep(FILE_POLL_SECONDS)
            try:
                current = await files.get_file(name=file.name or "")
            except genai_errors.APIError as exc:
                if int(exc.code or 0) == 429 or int(exc.code or 0) >= 500:
                    continue
                raise ProviderUnavailable("The AI couldn't process this video") from exc

    async def delete_file(self, name: str) -> bool:
        """Best effort (files also expire after 48 h on Google's side). Never raises."""
        transport = self._transport
        if transport is None or not hasattr(transport, "delete_file"):
            return False
        try:
            await transport.delete_file(name=name)  # type: ignore[attr-defined]
            return True
        except Exception as exc:
            log.warning("gemini file delete failed", extra={"error_type": type(exc).__name__})
            return False

    async def observe(
        self, request: PantryObservationRequest, meter: UsageMeter | None = None
    ) -> PantryObservation:
        plan = self.plan_observe(request)
        draft = await self.run(plan, PantryDraft, meter, salvage=_salvage_pantry)
        return to_pantry_observation(request.mode, draft)

    async def suggest(
        self, request: SubstitutionRequest, meter: UsageMeter | None = None
    ) -> SubstitutionResponse:
        draft = await self.run(self.plan_suggest(request), SubstitutionDraft, meter)
        return to_substitution_response(request, draft)

    async def answer(self, request: CoachRequest, meter: UsageMeter | None = None) -> CoachResponse:
        draft = await self.run(self.plan_coach(request), CoachDraft, meter)
        return to_coach_response(request, draft)

    async def inspect(
        self, request: InspectRequest, meter: UsageMeter | None = None
    ) -> InspectResponse:
        if self._transport is None:
            raise self.unavailable("visual inspection")
        if not request.image_bytes:
            raise ProviderOutputInvalid("No photo was received; take the photo again")
        draft = await self.run(self.plan_inspect(request), InspectDraft, meter)
        return to_inspect_response(request, draft)


# --- Draft → contract ----------------------------------------------------------------------


def to_coach_response(request: CoachRequest, draft: CoachDraft) -> CoachResponse:
    return CoachResponse(
        answer_text=draft.answer_text,
        grounding=draft.grounding,
        grounded_session_revision=request.session_revision,
        uncertainty=draft.uncertainty,
        safety_notice=draft.safety_notice,
        proposed_action=draft.proposed_action,
        requires_confirmation=draft.proposed_action is not None,
    )


def to_inspect_response(request: InspectRequest, draft: InspectDraft) -> InspectResponse:
    return InspectResponse(
        observation=draft.observation,
        step_alignment=draft.step_alignment,
        confidence=draft.confidence,
        limitations=draft.limitations,
        suggested_action=draft.suggested_action,
        food_safety_certified=False,
        grounded_revision=request.grounded_revision,
        recommended_step_change=None,  # visual classification never moves a step (PRD §8.6)
    )


def to_pantry_observation(
    mode: Literal["transcript", "photo"], draft: PantryDraft
) -> PantryObservation:
    return PantryObservation(
        mode=mode,
        candidates=[
            PantryCandidate(
                raw_label=c.raw_label,
                canonical_name=c.canonical_name,
                quantity=c.quantity,
                unit=c.unit,
                confidence=c.confidence,
                evidence=c.evidence,
                action="add",
                quantity_is_estimate=mode == "photo" and c.quantity is not None,
            )
            for c in draft.candidates
        ],
        notes=draft.notes,
        unknowns=draft.unknowns,
    )


def to_substitution_response(
    request: SubstitutionRequest, draft: SubstitutionDraft
) -> SubstitutionResponse:
    return SubstitutionResponse(
        target_ingredient=request.target_ingredient,
        suggestions=[
            SubstitutionSuggestion(target_ingredient=request.target_ingredient, **s.model_dump())
            for s in draft.suggestions
        ],
        cannot_substitute=draft.cannot_substitute,
        reason=draft.reason,
    )


PARTIAL_NOTE = "Some items couldn't be read. Check the list and add anything missing by hand."


def _salvage_pantry(text: str) -> PantryDraft | None:
    """An editable partial result (PRD §8.2): keep each candidate that validates on its own."""
    try:
        data = json.loads(text)
    except ValueError:
        return None
    if not isinstance(data, dict) or not isinstance(data.get("candidates"), list):
        return None
    kept: list[PantryCandidateDraft] = []
    for item in data["candidates"][:40]:
        try:
            kept.append(PantryCandidateDraft.model_validate(item))
        except pydantic.ValidationError:
            continue
    if not kept:
        return None
    return PantryDraft(
        candidates=kept, notes=[PARTIAL_NOTE], unknowns=["items that couldn't be read"]
    )
