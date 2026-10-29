"""Model-facing video extraction schema and its mapping onto ``ExtractedRecipeDraft`` (brief 008).

Gemini fills ``VideoExtractionDraft`` (structured output). The mock provider reads a fixture in
the same shape, so the demo path exercises exactly the same parsing and post-processing.

Rules applied here, whoever produced the draft:

* Timestamps come back as ``MM:SS`` (or ``H:MM:SS``) strings and are converted to ms. An
  unparseable or backwards span becomes "no span" for that step (no clip), never a failure.
* A quantity is kept only when the model says it was shown or spoken. Anything else is
  ``null`` with ``needs_review``: unknown stays unknown, nothing is invented (PRD §8.2).
* Ingredient ids are reassigned ``ing-1..n`` in order; step references to ids the model did not
  define are dropped.
"""

from __future__ import annotations

import json
import re
from typing import Literal

import pydantic
from pydantic import Field

from app.ai.providers.base import (
    ExtractedIngredient,
    ExtractedRecipeDraft,
    ExtractedStep,
    StrictModel,
)

MAX_VIDEO_INGREDIENTS = 60
MAX_VIDEO_STEPS = 40

QuantitySource = Literal["shown", "spoken", "not_stated"]
StepEvidence = Literal["shown", "spoken", "shown_and_spoken", "inferred"]


class VideoIngredientDraft(StrictModel):
    id: str = Field(min_length=1, max_length=16, description='Short id such as "ing-1"')
    name: str = Field(min_length=1, max_length=120)
    quantity: float | None = Field(default=None, ge=0)
    unit: str | None = Field(default=None, max_length=24)
    quantity_source: QuantitySource = Field(
        description='"shown" (on screen / packaging), "spoken" (said aloud), else "not_stated"'
    )
    preparation: str | None = Field(default=None, max_length=120)
    optional: bool = False
    confidence: float = Field(ge=0.0, le=1.0)


class VideoStepDraft(StrictModel):
    instruction: str = Field(min_length=1, max_length=600)
    start: str | None = Field(default=None, max_length=12, description="MM:SS, or null")
    end: str | None = Field(default=None, max_length=12, description="MM:SS, or null")
    ingredient_ids: list[str] = Field(default_factory=list, max_length=20)
    success_cues: list[str] = Field(default_factory=list, max_length=4)
    warnings: list[str] = Field(default_factory=list, max_length=4)
    estimated_minutes: int | None = Field(default=None, ge=0, le=600)
    evidence: StepEvidence
    confidence: float = Field(ge=0.0, le=1.0)


class VideoExtractionDraft(StrictModel):
    title: str | None = Field(default=None, max_length=120)
    summary: str | None = Field(default=None, max_length=400)
    servings: int | None = Field(default=None, ge=1, le=100)
    prep_minutes: int | None = Field(default=None, ge=0, le=1440)
    cook_minutes: int | None = Field(default=None, ge=0, le=1440)
    ingredients: list[VideoIngredientDraft] = Field(
        default_factory=list, max_length=MAX_VIDEO_INGREDIENTS
    )
    steps: list[VideoStepDraft] = Field(default_factory=list, max_length=MAX_VIDEO_STEPS)
    unknowns: list[str] = Field(default_factory=list, max_length=20)


_TS_RE = re.compile(r"^\s*(?:(\d{1,2}):)?(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\s*$")


def parse_timestamp(value: str | None) -> int | None:
    """``"MM:SS"``, ``"M:SS"``, ``"H:MM:SS"`` (optional ``.fff``) → ms; anything else → None."""
    if value is None:
        return None
    match = _TS_RE.match(value)
    if match is None:
        return None
    hours, minutes, seconds, frac = match.groups()
    if int(seconds) >= 60 or (hours is not None and int(minutes) >= 60):
        return None
    ms = (int(hours or 0) * 3600 + int(minutes) * 60 + int(seconds)) * 1000
    if frac:
        ms += int(frac.ljust(3, "0"))
    return ms


def to_extracted(draft: VideoExtractionDraft) -> ExtractedRecipeDraft:
    id_map: dict[str, str] = {}
    ingredients: list[ExtractedIngredient] = []
    for index, item in enumerate(draft.ingredients, start=1):
        new_id = f"ing-{index}"
        id_map.setdefault(item.id, new_id)
        stated = item.quantity_source in ("shown", "spoken") and item.quantity is not None
        quantity = item.quantity if stated and (item.quantity or 0) > 0 else None
        ingredients.append(
            ExtractedIngredient(
                id=new_id,
                name=item.name,
                quantity=quantity,
                unit=item.unit if quantity is not None else None,
                optional=item.optional,
                preparation=item.preparation,
                confidence=item.confidence,
                needs_review=quantity is None,
            )
        )
    steps: list[ExtractedStep] = []
    for index, step in enumerate(draft.steps):
        start = parse_timestamp(step.start)
        end = parse_timestamp(step.end)
        if start is None or end is None or end <= start:
            start = end = None
        refs: list[str] = []
        for ref in step.ingredient_ids:
            mapped = id_map.get(ref)
            if mapped is not None and mapped not in refs:
                refs.append(mapped)
        steps.append(
            ExtractedStep(
                id=f"step-{index + 1}",
                order=index,
                instruction=step.instruction,
                ingredient_refs=refs,
                estimated_minutes=step.estimated_minutes,
                success_cues=list(step.success_cues),
                warnings=list(step.warnings),
                source_start_ms=start,
                source_end_ms=end,
                evidence_origin="ai_extracted",
                confidence=step.confidence,
            )
        )
    confidences = [i.confidence for i in ingredients] + [s.confidence for s in steps]
    return ExtractedRecipeDraft(
        title=draft.title,
        summary=draft.summary,
        servings=draft.servings,
        prep_minutes=draft.prep_minutes,
        cook_minutes=draft.cook_minutes,
        ingredients=ingredients,
        steps=steps,
        unknowns=list(draft.unknowns),
        confidence=min(confidences) if confidences else 0.0,
        requires_review=True,
    )


PARTIAL_UNKNOWN = "Part of the AI answer couldn't be read. Check every step and ingredient."


def salvage_video(text: str) -> VideoExtractionDraft | None:
    """An editable partial draft (PRD §8.2) from malformed output: keep every ingredient and
    step that validates on its own, and the top-level scalars that do."""
    try:
        data = json.loads(text)
    except ValueError:
        return None
    if not isinstance(data, dict):
        return None
    ingredients: list[VideoIngredientDraft] = []
    for item in (data.get("ingredients") or [])[:MAX_VIDEO_INGREDIENTS]:
        try:
            ingredients.append(VideoIngredientDraft.model_validate(item))
        except pydantic.ValidationError:
            continue
    steps: list[VideoStepDraft] = []
    for item in (data.get("steps") or [])[:MAX_VIDEO_STEPS]:
        try:
            steps.append(VideoStepDraft.model_validate(item))
        except pydantic.ValidationError:
            continue
    if not ingredients and not steps:
        return None
    scalars: dict[str, object] = {}
    for key in ("title", "summary", "servings", "prep_minutes", "cook_minutes"):
        try:
            VideoExtractionDraft.model_validate({key: data.get(key)})
            scalars[key] = data.get(key)
        except pydantic.ValidationError:
            continue
    return VideoExtractionDraft(
        **scalars,  # type: ignore[arg-type]
        ingredients=ingredients,
        steps=steps,
        unknowns=[PARTIAL_UNKNOWN],
    )
