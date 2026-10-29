"""Extracted recipe → editable draft content (brief 008, PRD §8.2). Pure: no I/O.

Applied to every extraction, live or demo:

* Every model string is cleaned (control / bidi characters removed, length-limited to the draft
  limits) and passed through ``strip_model_claims``, so no AI text can certify doneness or
  safety or claim something is allergen-free. A field emptied by the filter stays empty for the
  creator to fill in; nothing is made up in its place.
* Every ingredient and step is marked ``evidence_origin="ai_extracted"``.
* Quantities were already nulled unless shown or spoken (``app.ai.video``); a null stays null.
* Spans are clamped to the probed duration, dropped when shorter than half a second, then
  padded by 1 s on each side (timestamps are approximate; the creator can trim).
"""

from __future__ import annotations

import re
import uuid

from app.ai.providers.base import ExtractedRecipeDraft
from app.ai.video import PARTIAL_UNKNOWN
from app.domains.recipes.draft_schemas import (
    _FORBIDDEN,
    INSTRUCTION_MAX,
    LIST_ITEM_MAX,
    MAX_INGREDIENTS,
    MAX_LIST_ITEMS,
    MAX_STEPS,
    NAME_MAX,
    PREPARATION_MAX,
    SUMMARY_MAX,
    TITLE_MAX,
    UNIT_MAX,
    DraftContent,
    DraftExtraction,
)
from app.domains.recipes.schemas import IngredientOut, StepOut
from app.domains.safety.content import is_high_risk, strip_model_claims

CLIP_PAD_MS = 1000
MIN_SPAN_MS = 500
MAX_UNKNOWNS = 20

DEMO_NOTICE = (
    "Demo extraction: AI is off, so this sample recipe was not read from your video. "
    "Replace it with your own ingredients and steps before publishing."
)

_WS_RE = re.compile(r"[ \t]+")


def clean_text(value: str | None, max_len: int, *, multiline: bool = False) -> str:
    if not value:
        return ""
    text = "".join(ch for ch in value if ch not in _FORBIDDEN)
    if not multiline:
        text = text.replace("\r", " ").replace("\n", " ")
    text = _WS_RE.sub(" ", text).strip()
    return text[:max_len].strip()


def safe_text(value: str | None, max_len: int, *, high_risk: bool, multiline: bool = False) -> str:
    kept, _dropped = strip_model_claims(
        clean_text(value, max_len, multiline=multiline), high_risk=high_risk
    )
    return kept[:max_len].strip()


def clamp_span(
    start_ms: int | None, end_ms: int | None, duration_ms: int
) -> tuple[int, int] | None:
    """Clamp to ``[0, duration]``, drop a span under ``MIN_SPAN_MS``, then pad ±1 s."""
    if start_ms is None or end_ms is None or duration_ms <= 0:
        return None
    start = min(max(start_ms, 0), duration_ms)
    end = min(max(end_ms, 0), duration_ms)
    if end - start < MIN_SPAN_MS:
        return None
    return max(start - CLIP_PAD_MS, 0), min(end + CLIP_PAD_MS, duration_ms)


def _list(values: list[str], *, high_risk: bool) -> list[str]:
    out: list[str] = []
    for value in values[:MAX_LIST_ITEMS]:
        kept = safe_text(value, LIST_ITEM_MAX, high_risk=high_risk, multiline=True)
        if kept:
            out.append(kept)
    return out


def build_content(
    extracted: ExtractedRecipeDraft,
    *,
    duration_ms: int,
    job_id: uuid.UUID,
    source_media_id: uuid.UUID | None,
    demo: bool,
    title_hint: str | None = None,
) -> DraftContent:
    corpus = [i.name for i in extracted.ingredients] + [s.instruction for s in extracted.steps]
    high_risk = is_high_risk(corpus)

    ingredients: list[IngredientOut] = []
    for item in extracted.ingredients[:MAX_INGREDIENTS]:
        ingredients.append(
            IngredientOut(
                id=item.id,
                name=safe_text(item.name, NAME_MAX, high_risk=high_risk),
                quantity=item.quantity,
                unit=(clean_text(item.unit, UNIT_MAX) or None)
                if item.quantity is not None
                else None,
                optional=item.optional,
                preparation=safe_text(item.preparation, PREPARATION_MAX, high_risk=high_risk)
                or None,
                evidence_origin="ai_extracted",
            )
        )
    known_ids = {i.id for i in ingredients}

    steps: list[StepOut] = []
    for index, step in enumerate(extracted.steps[:MAX_STEPS]):
        span = clamp_span(step.source_start_ms, step.source_end_ms, duration_ms)
        steps.append(
            StepOut(
                id=step.id,
                order=index,
                instruction=safe_text(
                    step.instruction, INSTRUCTION_MAX, high_risk=high_risk, multiline=True
                ),
                ingredient_refs=[r for r in step.ingredient_refs if r in known_ids],
                estimated_minutes=step.estimated_minutes,
                success_cues=_list(step.success_cues, high_risk=high_risk),
                warnings=_list(step.warnings, high_risk=high_risk),
                source_start_ms=span[0] if span else None,
                source_end_ms=span[1] if span else None,
                evidence_origin="ai_extracted",
            )
        )

    unknowns = [
        u
        for u in (safe_text(x, LIST_ITEM_MAX, high_risk=high_risk) for x in extracted.unknowns)
        if u
    ][:MAX_UNKNOWNS]
    title = clean_text(title_hint, TITLE_MAX) or safe_text(
        extracted.title, TITLE_MAX, high_risk=high_risk
    )
    return DraftContent(
        title=title or None,
        summary=safe_text(extracted.summary, SUMMARY_MAX, high_risk=high_risk, multiline=True)
        or None,
        servings=extracted.servings,
        prep_minutes=extracted.prep_minutes,
        cook_minutes=extracted.cook_minutes,
        ingredients=ingredients,
        steps=steps,
        extraction=DraftExtraction(
            job_id=job_id,
            source_media_id=source_media_id,
            demo=demo,
            partial=PARTIAL_UNKNOWN in extracted.unknowns,
            unknowns=unknowns,
            notice=DEMO_NOTICE if demo else None,
        ),
    )
