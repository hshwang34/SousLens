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
DEFAULT_PHOTO_FIXTURE = "demo_counter"

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
    "eleven": 11,
    "twelve": 12,
    "thirteen": 13,
    "fourteen": 14,
    "fifteen": 15,
    "sixteen": 16,
    "seventeen": 17,
    "eighteen": 18,
    "nineteen": 19,
    "twenty": 20,
    "dozen": 12,
    "half": 0.5,
    "quarter": 0.25,
}

# Parser-level units. Packaging words (can, jar, bunch, …) are kept here so the evidence reads
# naturally; the API maps anything outside the contract unit list to "amount unknown".
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
    "bottle": "bottle",
    "bottles": "bottle",
    "bag": "bag",
    "bags": "bag",
    "box": "box",
    "boxes": "box",
    "pack": "pack",
    "packs": "pack",
    "packet": "pack",
    "packets": "pack",
    "bunch": "bunch",
    "bunches": "bunch",
    "g": "g",
    "gram": "g",
    "grams": "g",
    "kg": "kg",
    "kilo": "kg",
    "kilos": "kg",
    "kilogram": "kg",
    "kilograms": "kg",
    "ml": "ml",
    "milliliter": "ml",
    "milliliters": "ml",
    "l": "l",
    "liter": "l",
    "liters": "l",
    "litre": "l",
    "litres": "l",
    "stick": "stick",
    "sticks": "stick",
    "head": "head",
    "heads": "head",
    "fl_oz": "fl_oz",
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

_LEADS = (
    "i have",
    "i've got",
    "i got",
    "i also have",
    "we have",
    "we've got",
    "we got",
    "there is",
    "there's",
    "there are",
    "got",
    "have",
    "oh",
    "and",
    "also",
    "plus",
)
_VAGUE_RE = re.compile(
    r"\b(?:a little(?: bit of)?|a bit of|a lot of|lots of|plenty of|a few|a handful of|"
    r"several|some|loads of|bit of)\b"
)
_FILLER_RE = re.compile(r"\b(?:um+|uh+|uhm+|erm+|er|hmm+|you know|like|okay|ok|so|well)\b")
_CORRECTION_RE = re.compile(
    r"\b(?:no wait|wait no|no no|scratch that|make that|actually|i mean|sorry|correction|wait)\b"
)
_NEGATION_RE = re.compile(
    r"^(?:no more|no|not any|not|out of|ran out of|we're out of|i'm out of|don't have|"
    r"do not have|without)\s+"
)
_LOCATION_RE = re.compile(
    r"\b(?:in|on) (?:the|my) (?:fridge|freezer|pantry|cupboard|counter|shelf|cabinet)\b"
)
_SPLIT_RE = re.compile(r",|;|\.(?=\s|$)|\band\b(?! a half)|\bplus\b|\balso\b|\bbut\b|\bthen\b")
_NUMERIC_RE = re.compile(r"^(\d+(?:\.\d+)?|\d+/\d+)$")
_CORR = "@corr"
_DROP_WORDS = frozenset({"some", "the", "of", "an", "a", "my", "our", "fresh-ish"})
_SAFETY_WORDS = ("done", "safe", "cooked through", "raw", "undercooked", "temperature", "pink")


def _strip_leads(text: str) -> str:
    changed = True
    while changed:
        changed = False
        for lead in _LEADS:
            if text == lead:
                return ""
            if text.startswith(lead + " "):
                text = text[len(lead) :].strip()
                changed = True
    return text


def _preprocess(transcript: str) -> str:
    text = transcript.strip().lower().replace("\u2019", "'")
    text = re.sub(r"(\d)([a-z])", r"\1 \2", text)  # 500g → 500 g
    text = re.sub(r"\bfl(?:uid)?\.? ?(?:oz|ounces?)\b", "fl_oz", text)
    text = re.sub(r"\bhalf a dozen\b", "6", text)
    text = re.sub(r"\ba dozen\b", "12", text)
    text = re.sub(r"\ba couple(?: of)?\b", "2", text)
    text = re.sub(r"\bcouple of\b", "2", text)
    for word, value in _NUMBER_WORDS.items():
        if word not in ("a", "an", "half", "quarter", "dozen") and value == int(value):
            text = re.sub(rf"\b{word} and a half\b", f"{int(value)}.5", text)
    text = re.sub(r"\b(\d+) and a half\b", r"\1.5", text)
    text = re.sub(r"\b(\d+) (\d+)/(\d+)\b", lambda m: str(int(m[1]) + int(m[2]) / int(m[3])), text)
    text = _LOCATION_RE.sub(" ", text)
    text = _FILLER_RE.sub(" ", text)
    text = _CORRECTION_RE.sub(f", {_CORR} ,", text)
    return text


def _parse_quantity(tokens: list[str]) -> tuple[float | None, list[str]]:
    if not tokens:
        return None, tokens
    head = tokens[0]
    if _NUMERIC_RE.match(head):
        if "/" in head:
            num, den = head.split("/")
            qty = float(num) / float(den) if float(den) else None
        else:
            qty = float(head)
        rest = tokens[1:]
    elif head in _NUMBER_WORDS:
        qty = _NUMBER_WORDS[head]
        rest = tokens[1:]
        # "half a cup", "half an onion"
        if rest and rest[0] in ("a", "an", "of"):
            rest = rest[1:]
    else:
        return None, tokens
    if qty is not None and rest and rest[0] == "dozen":  # "two dozen eggs"
        qty, rest = qty * 12, rest[1:]
    return qty, rest


def _parse_unit(tokens: list[str]) -> tuple[str | None, list[str]]:
    if tokens and tokens[0] in _UNITS:
        rest = tokens[1:]
        if rest and rest[0] == "of":
            rest = rest[1:]
        return _UNITS[tokens[0]], rest
    return None, tokens


def _parse_chunk(chunk: str) -> tuple[str | None, float | None, str | None, bool]:
    """→ (label, quantity, unit, vague). ``label`` is None for a bare amount ("make that two")."""
    phrase = re.sub(r"[^\w\s/.'-]", " ", chunk)
    phrase = re.sub(r"\s+", " ", phrase).strip(" .")
    phrase = _strip_leads(phrase)
    vague = bool(_VAGUE_RE.search(phrase))
    phrase = _VAGUE_RE.sub(" ", phrase).strip()
    phrase = _strip_leads(re.sub(r"\s+", " ", phrase))
    tokens = phrase.split()
    quantity, tokens = (None, tokens) if vague else _parse_quantity(tokens)
    unit, tokens = _parse_unit(tokens)
    tokens = [t for t in tokens if t not in _DROP_WORDS]
    label = " ".join(tokens) or None
    return label, quantity, unit, vague


def _confidence(label: str) -> float:
    # Identity comes from the user's own words; very long phrases are likely mis-heard.
    return 0.65 if len(label.split()) > 4 else 0.9


def parse_transcript(transcript: str) -> list[PantryCandidate]:
    """Deterministic spoken-pantry parser (mock mode, PAN-02).

    Splits on commas / "and" / "plus" / "but", drops fillers ("um", "like"), reads leading
    quantities (digits, fractions, number words, "a dozen", "a couple", "one and a half") and
    units, applies corrections ("no wait, three onions" replaces the earlier onions; "make that
    two" fixes the last amount), drops negations ("no milk") and merges repeats. Vague amounts
    ("some", "a few") are never turned into numbers.
    """
    candidates: list[PantryCandidate] = []
    correcting = False
    for raw_chunk in _SPLIT_RE.split(_preprocess(transcript)):
        chunk = raw_chunk.strip()
        if not chunk:
            continue
        if chunk == _CORR:
            correcting = True
            continue
        negated = _NEGATION_RE.match(_strip_leads(chunk))
        if negated:
            label, *_ = _parse_chunk(_strip_leads(chunk)[negated.end() :])
            if label:
                canonical = _ALIASES.get(label, label)
                candidates = [c for c in candidates if c.canonical_name != canonical]
            correcting = False
            continue
        label, quantity, unit, _vague = _parse_chunk(chunk)
        evidence = f"transcript: '{chunk}'"
        if label is None:
            # A bare amount only means something as a correction of the previous item.
            if correcting and candidates and (quantity is not None or unit is not None):
                last = candidates[-1]
                candidates[-1] = last.model_copy(
                    update={"quantity": quantity, "unit": unit, "evidence": evidence}
                )
            correcting = False
            continue
        canonical = _ALIASES.get(label, label)
        candidate = PantryCandidate(
            raw_label=label,
            canonical_name=canonical,
            quantity=quantity,
            unit=unit,
            confidence=_confidence(label),
            evidence=evidence,
            action="add",
        )
        same = next((i for i, c in enumerate(candidates) if c.canonical_name == canonical), None)
        if correcting and candidates:
            candidates[same if same is not None else len(candidates) - 1] = candidate
        elif same is not None:
            if candidates[same].quantity is None and quantity is not None:
                candidates[same] = candidate
        else:
            candidates.append(candidate)
        correcting = False
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
        fixture = self._photo_fixture(image_ref or DEFAULT_PHOTO_FIXTURE)
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
            unknowns=["what is in this photo"],
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
