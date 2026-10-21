"""MockAIProvider: deterministic, schema-valid outputs with zero inference spend.

Keeps every typed path usable with ``AI_PROVIDER=mock`` (CLAUDE.md "AI-off still works").
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

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
    SubstitutionRequest,
    SubstitutionResponse,
    SubstitutionSuggestion,
)

PHOTO_FIXTURE_SUBDIR = "pantry_observations"

_NUMBER_WORDS: dict[str, float] = {
    "a": 1,
    "an": 1,
    "one": 1,
    "two": 2,
    "three": 3,
    "four": 4,
    "five": 5,
    "six": 6,
    "seven": 7,
    "eight": 8,
    "nine": 9,
    "ten": 10,
    "dozen": 12,
    "half": 0.5,
    "quarter": 0.25,
    "couple": 2,
    "few": 3,
}

_UNITS: dict[str, str] = {
    "lb": "lb",
    "lbs": "lb",
    "pound": "lb",
    "pounds": "lb",
    "oz": "oz",
    "ounce": "oz",
    "ounces": "oz",
    "cup": "cup",
    "cups": "cup",
    "tbsp": "tbsp",
    "tablespoon": "tbsp",
    "tablespoons": "tbsp",
    "tsp": "tsp",
    "teaspoon": "tsp",
    "teaspoons": "tsp",
    "clove": "clove",
    "cloves": "clove",
    "can": "can",
    "cans": "can",
    "jar": "jar",
    "jars": "jar",
    "bag": "bag",
    "bags": "bag",
    "bunch": "bunch",
    "bunches": "bunch",
    "g": "g",
    "gram": "g",
    "grams": "g",
    "kg": "kg",
    "kilo": "kg",
    "kilos": "kg",
    "ml": "ml",
    "l": "l",
    "liter": "l",
    "liters": "l",
    "litre": "l",
    "litres": "l",
    "stick": "stick",
    "sticks": "stick",
    "head": "head",
    "heads": "head",
}

_ALIASES: dict[str, str] = {
    "green onion": "scallion",
    "green onions": "scallion",
    "scallions": "scallion",
    "spring onion": "scallion",
    "spring onions": "scallion",
    "eggs": "egg",
    "onions": "onion",
    "tomatoes": "tomato",
    "chicken thigh": "chicken thighs",
    "korean chili paste": "gochujang",
    "korean chili flakes": "gochugaru",
    "korean red pepper flakes": "gochugaru",
    "soy": "soy sauce",
    "garlic cloves": "garlic",
    "cucumbers": "cucumber",
}

_FILLER = ("i have", "i've got", "i got", "we have", "we've got", "there is", "there are", "got")
_SPLIT_RE = re.compile(r",|;|\band\b|\bplus\b|\balso\b", re.IGNORECASE)
_NUMERIC_RE = re.compile(r"^(\d+(?:\.\d+)?|\d+/\d+)$")
_SAFETY_WORDS = ("done", "safe", "cooked through", "raw", "undercooked", "temperature", "pink")


def _strip_filler(text: str) -> str:
    cleaned = text.strip().lower()
    for prefix in _FILLER:
        if cleaned.startswith(prefix + " "):
            cleaned = cleaned[len(prefix) :].strip()
            break
    return cleaned


def _parse_quantity(tokens: list[str]) -> tuple[float | None, list[str]]:
    if not tokens:
        return None, tokens
    head = tokens[0]
    if _NUMERIC_RE.match(head):
        if "/" in head:
            num, den = head.split("/")
            return float(num) / float(den), tokens[1:]
        return float(head), tokens[1:]
    if head in _NUMBER_WORDS:
        qty = _NUMBER_WORDS[head]
        rest = tokens[1:]
        # "half a cup", "a couple of"
        if rest and rest[0] in ("a", "an", "of"):
            rest = rest[1:]
        return qty, rest
    return None, tokens


def _parse_unit(tokens: list[str]) -> tuple[str | None, list[str]]:
    if tokens and tokens[0] in _UNITS:
        rest = tokens[1:]
        if rest and rest[0] == "of":
            rest = rest[1:]
        return _UNITS[tokens[0]], rest
    return None, tokens


def parse_transcript(transcript: str) -> list[PantryCandidate]:
    """Split on commas / "and", pull leading quantity words + units, normalize aliases."""
    candidates: list[PantryCandidate] = []
    for chunk in _SPLIT_RE.split(_strip_filler(transcript)):
        phrase = re.sub(r"[^\w\s/.-]", " ", chunk).strip()
        if not phrase:
            continue
        tokens = phrase.split()
        quantity, tokens = _parse_quantity(tokens)
        unit, tokens = _parse_unit(tokens)
        tokens = [t for t in tokens if t not in ("some", "the", "of", "an", "a")]
        if not tokens:
            continue
        raw_label = " ".join(tokens)
        canonical = _ALIASES.get(raw_label, raw_label)
        candidates.append(
            PantryCandidate(
                raw_label=raw_label,
                canonical_name=canonical,
                quantity=quantity,
                unit=unit,
                confidence=0.9 if quantity is not None or unit is not None else 0.8,
                evidence=f"transcript: '{chunk.strip()}'",
                action="add",
            )
        )
    return candidates


def _normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip().lower())


def _mentions_any(text: str, tokens: set[str]) -> bool:
    """True when any token appears as a whole word/phrase in ``text`` (both normalized)."""
    haystack = _normalize(text)
    return any(re.search(rf"(?<![a-z0-9]){re.escape(t)}(?![a-z0-9])", haystack) for t in tokens)


def _decline_for_allergy(target_ingredient: str) -> SubstitutionResponse:
    return SubstitutionResponse(
        target_ingredient=target_ingredient,
        cannot_substitute=True,
        reason="a user-reported allergy matches this ingredient or its proposed substitute; check"
        " the product label and trusted clinical guidance instead of substituting",
    )


class MockAIProvider:
    name = "mock"

    def __init__(self, fixtures_dir: Path) -> None:
        self.fixtures_dir = Path(fixtures_dir)

    def describe(self) -> dict[str, Any]:
        return {"name": self.name, "fixtures_dir": str(self.fixtures_dir)}

    # RecipeExtractor
    async def extract(self, request: ExtractionRequest) -> ExtractedRecipeDraft:
        title = request.title_hint or Path(request.media_ref).stem.replace("-", " ").title() or None
        return ExtractedRecipeDraft(
            title=title,
            summary=None,
            ingredients=[],
            steps=[],
            unknowns=[
                "mock provider does not analyze video; ingredients and steps must be authored",
            ],
            confidence=0.0,
            requires_review=True,
        )

    # PantryExtractor
    async def observe(self, request: PantryObservationRequest) -> PantryObservation:
        if request.mode == "transcript":
            candidates = parse_transcript(request.transcript or "")
            notes = [] if candidates else ["no ingredients recognized in transcript"]
            return PantryObservation(mode="transcript", candidates=candidates, notes=notes)
        return self._observe_photo(request.image_ref)

    def _observe_photo(self, image_ref: str | None) -> PantryObservation:
        fixture = self._photo_fixture(image_ref)
        if fixture is not None:
            return PantryObservation.model_validate({"mode": "photo", **fixture})
        return PantryObservation(
            mode="photo",
            candidates=[
                PantryCandidate(
                    raw_label="unidentified item",
                    canonical_name=None,
                    confidence=0.1,
                    evidence="no fixture for this image; contents not identifiable",
                    action="ignore",
                )
            ],
            notes=["I can't confirm what this is from the image. Try a closer, labeled shot."],
        )

    def _photo_fixture(self, image_ref: str | None) -> dict[str, Any] | None:
        if not image_ref:
            return None
        stem = Path(image_ref).stem
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", stem):
            return None
        path = self.fixtures_dir / "expected_outputs" / PHOTO_FIXTURE_SUBDIR / f"{stem}.json"
        if not path.is_file():
            return None
        with path.open(encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else None

    # SubstitutionAdvisor
    async def suggest(self, request: SubstitutionRequest) -> SubstitutionResponse:
        target = _normalize(request.target_ingredient)
        blocked = {_normalize(a) for a in request.constraints.allergies} - {""}
        if _mentions_any(target, blocked):
            return _decline_for_allergy(request.target_ingredient)
        table: dict[str, tuple[str, str, str]] = {
            "scallion": ("chives", "close_equivalent", "1:1"),
            "green onion": ("chives", "close_equivalent", "1:1"),
            "mirin": ("rice vinegar + a pinch of sugar", "flavor_adaptation", "1 tbsp + 1/2 tsp"),
            "rice vinegar": ("apple cider vinegar", "flavor_adaptation", "1:1"),
            "honey": ("brown sugar", "flavor_adaptation", "3/4 of the amount"),
        }
        hit = table.get(target)
        if hit is None:
            return SubstitutionResponse(
                target_ingredient=request.target_ingredient,
                cannot_substitute=True,
                reason="no reviewed substitution rule for this ingredient in mock mode",
            )
        candidate, kind, ratio = hit
        adjusted_steps: list[str] = []
        # Safety precedence (PRD §8.4): a user allergy anywhere in the proposed swap wins.
        if any(_mentions_any(text, blocked) for text in (candidate, ratio, *adjusted_steps)):
            return _decline_for_allergy(request.target_ingredient)
        pantry = {_normalize(p) for p in request.pantry_items}
        return SubstitutionResponse(
            target_ingredient=request.target_ingredient,
            suggestions=[
                SubstitutionSuggestion(
                    target_ingredient=request.target_ingredient,
                    candidate=candidate,
                    kind=kind,  # type: ignore[arg-type]
                    ratio_or_amount=ratio,
                    rationale="deterministic mock rule",
                    impact_flavor="minor",
                    impact_texture="minor",
                    adjusted_steps=adjusted_steps,
                    confidence=0.7 if candidate.split(" ")[0] in pantry else 0.5,
                    risks=[],
                )
            ],
        )

    # CookingCoach
    async def answer(self, request: CoachRequest) -> CoachResponse:
        step = request.current_step
        parts = [f"The recipe says (step {step.order + 1}): {step.instruction}"]
        if step.success_cues:
            parts.append("Look for: " + "; ".join(step.success_cues) + ".")
        grounding = [GroundingRef(type="recipe_step", id=step.id)]
        if step.creator_note:
            parts.append(f"Creator note: {step.creator_note}")
            grounding.append(GroundingRef(type="creator_note", id=step.id))
        if request.visual_observation_id:
            grounding.append(
                GroundingRef(type="visual_observation", id=request.visual_observation_id)
            )
        safety_notice = step.warnings[0] if step.warnings else None
        if any(word in request.query.lower() for word in _SAFETY_WORDS):
            safety_notice = (
                "I can't confirm doneness or safety from a description or image. Check with an"
                " instant-read thermometer against trusted guidance."
            )
        return CoachResponse(
            answer_text=" ".join(parts),
            grounding=grounding,
            grounded_session_revision=request.session_revision,
            uncertainty="low",
            safety_notice=safety_notice,
            proposed_action=None,
            requires_confirmation=False,
        )

    # VisualObserver
    async def inspect(self, request: InspectRequest) -> InspectResponse:
        return InspectResponse(
            observation="I can't make out detail from this single frame in mock mode.",
            step_alignment=f"The recipe asks: {request.current_step.instruction}",
            confidence="medium",
            limitations=[
                "mock observer does not analyze pixels",
                "a single frame cannot show everything in the pan",
            ],
            suggested_action="Compare against the step's success cues and ask again if unsure.",
            food_safety_certified=False,
            grounded_revision=request.grounded_revision,
            recommended_step_change=None,
        )
