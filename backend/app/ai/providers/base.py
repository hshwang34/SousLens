"""Typed contracts for every AI responsibility (PRD §8.1-8.5, §10.2, §11.2, Appendix A).

One Protocol per responsibility; every request and response is a Pydantic model so model output
is always parsed, never trusted raw. Providers may implement several Protocols on one object.
"""

from __future__ import annotations

from typing import Any, Literal, Protocol, runtime_checkable

from pydantic import BaseModel, ConfigDict, Field

Confidence = float
UncertaintyLevel = Literal["low", "medium", "high"]
EvidenceOrigin = Literal["creator_authored", "creator_reviewed", "ai_extracted"]


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


# --- 8.2 Recipe extraction ------------------------------------------------------------------


class ExtractionRequest(StrictModel):
    media_ref: str = Field(description="Storage key or local path of the creator's own video")
    duration_ms: int | None = Field(default=None, ge=0)
    title_hint: str | None = None
    creator_notes: list[str] = Field(default_factory=list)
    language: str = "en"


class ExtractedIngredient(StrictModel):
    id: str
    name: str
    quantity: float | None = None
    unit: str | None = None
    optional: bool = False
    preparation: str | None = None
    evidence_text: str | None = None
    confidence: Confidence = Field(ge=0.0, le=1.0)
    needs_review: bool = False


class ExtractedStep(StrictModel):
    id: str
    order: int = Field(ge=0)
    instruction: str
    ingredient_refs: list[str] = Field(default_factory=list)
    estimated_minutes: int | None = Field(default=None, ge=0)
    success_cues: list[str] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)
    source_start_ms: int | None = Field(default=None, ge=0)
    source_end_ms: int | None = Field(default=None, ge=0)
    evidence_text: str | None = None
    evidence_origin: EvidenceOrigin = "ai_extracted"
    confidence: Confidence = Field(ge=0.0, le=1.0)


class ExtractedRecipeDraft(StrictModel):
    title: str | None
    summary: str | None = None
    servings: int | None = Field(default=None, ge=1)
    prep_minutes: int | None = Field(default=None, ge=0)
    cook_minutes: int | None = Field(default=None, ge=0)
    ingredients: list[ExtractedIngredient] = Field(default_factory=list)
    steps: list[ExtractedStep] = Field(default_factory=list)
    unknowns: list[str] = Field(
        default_factory=list, description="What the extractor could not determine reliably"
    )
    confidence: Confidence = Field(ge=0.0, le=1.0)
    requires_review: bool = True


# --- 8.3 / 10.2 Pantry observation --------------------------------------------------------


class PantryObservationRequest(StrictModel):
    """``image_bytes`` is the in-memory upload (never written anywhere, PRIV-01); it is excluded
    from dumps and reprs so it cannot leak into logs. ``image_ref`` is a fixture key for the mock
    provider only."""

    mode: Literal["transcript", "photo"]
    transcript: str | None = None
    image_ref: str | None = Field(default=None, description="Mock fixture key or filename")
    image_bytes: bytes | None = Field(default=None, exclude=True, repr=False)
    image_mime_type: str | None = None


class PantryCandidate(StrictModel):
    raw_label: str
    canonical_name: str | None
    quantity: float | None = None
    unit: str | None = None
    confidence: Confidence = Field(ge=0.0, le=1.0)
    evidence: str
    action: Literal["add", "update", "ignore"] = "add"
    quantity_is_estimate: bool = False


class PantryObservation(StrictModel):
    mode: Literal["transcript", "photo"]
    candidates: list[PantryCandidate]
    requires_confirmation: Literal[True] = True
    notes: list[str] = Field(default_factory=list)
    unknowns: list[str] = Field(
        default_factory=list, description="What could not be identified (PRD §8.3)"
    )


# --- 8.4 Substitution ---------------------------------------------------------------------


class SubstitutionConstraints(StrictModel):
    allergies: list[str] = Field(default_factory=list)
    dietary_restrictions: list[str] = Field(default_factory=list)
    preferences: list[str] = Field(default_factory=list)


class SubstitutionRequest(StrictModel):
    target_ingredient: str
    recipe_title: str
    recipe_step_context: list[str] = Field(default_factory=list)
    recipe_warnings: list[str] = Field(default_factory=list)
    pantry_items: list[str] = Field(default_factory=list)
    constraints: SubstitutionConstraints = Field(default_factory=SubstitutionConstraints)


SubstitutionKind = Literal[
    "close_equivalent", "flavor_adaptation", "structural_substitution", "not_recommended"
]


class SubstitutionSuggestion(StrictModel):
    target_ingredient: str
    candidate: str
    kind: SubstitutionKind
    ratio_or_amount: str
    rationale: str
    impact_flavor: str
    impact_texture: str
    adjusted_steps: list[str] = Field(default_factory=list)
    confidence: Confidence = Field(ge=0.0, le=1.0)
    risks: list[str] = Field(default_factory=list)
    requires_user_confirmation: Literal[True] = True


class SubstitutionResponse(StrictModel):
    target_ingredient: str
    suggestions: list[SubstitutionSuggestion] = Field(default_factory=list)
    cannot_substitute: bool = False
    reason: str | None = None


# --- 8.5 Coach grounding packet + Appendix A output -----------------------------------------


class StepSummary(StrictModel):
    id: str
    order: int = Field(ge=0)
    instruction: str
    success_cues: list[str] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)
    creator_note: str | None = None
    source_clip_id: str | None = None


class ApprovedSubstitution(StrictModel):
    ingredient_id: str
    replacement: str
    reason: str


class TimerSummary(StrictModel):
    id: str
    label: str
    target_at: str


class TranscriptTurn(StrictModel):
    role: Literal["user", "assistant"]
    text: str


class CoachRequest(StrictModel):
    recipe_id: str
    recipe_version_id: str
    version_number: int = Field(ge=1)
    title: str
    servings: int = Field(ge=1)
    ingredients: list[str] = Field(default_factory=list, description="Original amounts + units")
    current_step: StepSummary
    previous_step: StepSummary | None = None
    next_step: StepSummary | None = None
    approved_substitutions: list[ApprovedSubstitution] = Field(default_factory=list)
    relevant_pantry: list[str] = Field(default_factory=list)
    recent_turns: list[TranscriptTurn] = Field(default_factory=list, max_length=10)
    active_timers: list[TimerSummary] = Field(default_factory=list)
    user_preferences: list[str] = Field(default_factory=list)
    session_revision: int = Field(ge=0)
    query: str
    visual_observation_id: str | None = None


GroundingType = Literal[
    "recipe_step", "recipe_ingredient", "creator_note", "visual_observation", "substitution"
]


class GroundingRef(StrictModel):
    type: GroundingType
    id: str


class ProposedAction(StrictModel):
    command: Literal["next", "back", "jump_to_step", "pause", "resume", "complete", "start_timer"]
    step_index: int | None = None
    timer_label: str | None = None
    timer_seconds: int | None = Field(default=None, ge=1)


class CoachResponse(StrictModel):
    answer_text: str
    grounding: list[GroundingRef] = Field(default_factory=list)
    grounded_session_revision: int = Field(ge=0)
    uncertainty: UncertaintyLevel = "low"
    safety_notice: str | None = None
    proposed_action: ProposedAction | None = None
    requires_confirmation: bool = False


# --- 11.2 Visual inspect ------------------------------------------------------------------


class InspectRequest(StrictModel):
    session_id: str
    grounded_revision: int = Field(ge=0)
    query: str
    image_ref: str
    mime_type: str = "image/jpeg"
    captured_at: str | None = None
    current_step: StepSummary


class InspectResponse(StrictModel):
    observation: str
    step_alignment: str
    confidence: UncertaintyLevel
    limitations: list[str] = Field(default_factory=list)
    suggested_action: str | None = None
    food_safety_certified: Literal[False] = False
    grounded_revision: int = Field(ge=0)
    recommended_step_change: int | None = None


# --- Protocols ----------------------------------------------------------------------------


@runtime_checkable
class RecipeExtractor(Protocol):
    async def extract(self, request: ExtractionRequest) -> ExtractedRecipeDraft: ...


@runtime_checkable
class PantryExtractor(Protocol):
    async def observe(self, request: PantryObservationRequest) -> PantryObservation: ...


@runtime_checkable
class SubstitutionAdvisor(Protocol):
    async def suggest(self, request: SubstitutionRequest) -> SubstitutionResponse: ...


@runtime_checkable
class CookingCoach(Protocol):
    async def answer(self, request: CoachRequest) -> CoachResponse: ...


@runtime_checkable
class VisualObserver(Protocol):
    async def inspect(self, request: InspectRequest) -> InspectResponse: ...


@runtime_checkable
class AIProvider(
    RecipeExtractor, PantryExtractor, SubstitutionAdvisor, CookingCoach, VisualObserver, Protocol
):
    name: str

    def describe(self) -> dict[str, Any]: ...
