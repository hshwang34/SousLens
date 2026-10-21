"""MockAIProvider outputs validate against the shared schemas; Gemini stub refuses."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.ai.providers.base import (
    AIProvider,
    CoachRequest,
    CoachResponse,
    CookingCoach,
    ExtractedRecipeDraft,
    ExtractionRequest,
    InspectRequest,
    InspectResponse,
    PantryExtractor,
    PantryObservation,
    PantryObservationRequest,
    RecipeExtractor,
    StepSummary,
    SubstitutionAdvisor,
    SubstitutionConstraints,
    SubstitutionRequest,
    SubstitutionResponse,
    VisualObserver,
)
from app.ai.providers.gemini import GeminiProvider
from app.ai.providers.mock import MockAIProvider, parse_transcript
from app.ai.registry import build_provider
from app.core.config import Settings
from app.core.errors import ProviderNotConfigured
from tests.conftest import TEST_JWT_SECRET

FIXTURES_DIR = Path(__file__).resolve().parents[2].parent / "fixtures"


def mock_settings() -> Settings:
    return Settings(ai_provider="mock", jwt_secret=TEST_JWT_SECRET, auth_mode="dev")


def gemini_settings() -> Settings:
    return Settings(ai_provider="gemini", jwt_secret=TEST_JWT_SECRET, auth_mode="dev")


@pytest.fixture
def provider() -> MockAIProvider:
    return MockAIProvider(FIXTURES_DIR)


def step(**overrides: object) -> StepSummary:
    base = {
        "id": "step-5",
        "order": 4,
        "instruction": "Flip each piece and cook 5 to 6 minutes more.",
        "success_cues": ["Glaze thickens", "Thermometer reads 165°F"],
        "warnings": ["Do not judge doneness by color alone."],
        "creator_note": "Spoon the marinade over.",
    }
    base.update(overrides)
    return StepSummary.model_validate(base)


def test_mock_satisfies_every_protocol(provider: MockAIProvider) -> None:
    for proto in (
        RecipeExtractor,
        PantryExtractor,
        SubstitutionAdvisor,
        CookingCoach,
        VisualObserver,
        AIProvider,
    ):
        assert isinstance(provider, proto)


# --- pantry: transcript -------------------------------------------------------------------


def test_transcript_parser_handles_quantities_units_and_aliases() -> None:
    out = parse_transcript(
        "I have half an onion, 3 pounds of chicken, gochujang and two eggs, a bunch of green onions"
    )
    by_name = {c.canonical_name: c for c in out}
    assert set(by_name) == {"onion", "chicken", "gochujang", "egg", "scallion"}
    assert by_name["onion"].quantity == 0.5 and by_name["onion"].unit is None
    assert by_name["chicken"].quantity == 3 and by_name["chicken"].unit == "lb"
    assert by_name["gochujang"].quantity is None
    assert by_name["egg"].quantity == 2
    assert by_name["scallion"].raw_label == "green onions"
    assert by_name["scallion"].quantity == 1 and by_name["scallion"].unit == "bunch"


async def test_transcript_observation_validates_and_requires_confirmation(
    provider: MockAIProvider,
) -> None:
    request = PantryObservationRequest(mode="transcript", transcript="gochujang, 2 lb chicken")
    obs = await provider.observe(request)
    PantryObservation.model_validate(obs.model_dump())
    assert obs.requires_confirmation is True
    assert [c.canonical_name for c in obs.candidates] == ["gochujang", "chicken"]
    assert all(c.evidence.startswith("transcript:") for c in obs.candidates)


async def test_empty_transcript_yields_no_candidates(provider: MockAIProvider) -> None:
    obs = await provider.observe(PantryObservationRequest(mode="transcript", transcript="  "))
    assert obs.candidates == []
    assert obs.notes


async def test_same_transcript_is_deterministic(provider: MockAIProvider) -> None:
    req = PantryObservationRequest(mode="transcript", transcript="soy, 4 cloves garlic")
    assert await provider.observe(req) == await provider.observe(req)


# --- pantry: photo ------------------------------------------------------------------------


async def test_photo_with_fixture_is_looked_up_by_filename(provider: MockAIProvider) -> None:
    obs = await provider.observe(
        PantryObservationRequest(mode="photo", image_ref="uploads/abc/gochujang_jar.jpg")
    )
    assert obs.mode == "photo"
    labels = [c.raw_label for c in obs.candidates]
    assert labels == ["Gochujang", "unlabeled jar"]
    assert obs.candidates[1].canonical_name is None
    assert obs.candidates[1].action == "ignore"


async def test_photo_without_fixture_is_unknown_not_fabricated(provider: MockAIProvider) -> None:
    obs = await provider.observe(PantryObservationRequest(mode="photo", image_ref="mystery.heic"))
    assert len(obs.candidates) == 1
    assert obs.candidates[0].canonical_name is None
    assert obs.candidates[0].confidence < 0.6
    assert obs.candidates[0].action == "ignore"


async def test_photo_fixture_lookup_rejects_path_tricks(provider: MockAIProvider) -> None:
    obs = await provider.observe(PantryObservationRequest(mode="photo", image_ref="../../x.jpg"))
    assert obs.candidates[0].canonical_name is None


# --- extraction ---------------------------------------------------------------------------


async def test_extraction_returns_reviewable_empty_draft(provider: MockAIProvider) -> None:
    draft = await provider.extract(ExtractionRequest(media_ref="videos/kimchi-fried-rice.mp4"))
    ExtractedRecipeDraft.model_validate(draft.model_dump())
    assert draft.title == "Kimchi Fried Rice"
    assert draft.steps == [] and draft.ingredients == []
    assert draft.requires_review is True
    assert draft.unknowns


# --- substitutions ------------------------------------------------------------------------


async def test_substitution_declines_user_allergen(provider: MockAIProvider) -> None:
    res = await provider.suggest(
        SubstitutionRequest(
            target_ingredient="Honey",
            recipe_title="x",
            constraints=SubstitutionConstraints(allergies=["honey"]),
        )
    )
    SubstitutionResponse.model_validate(res.model_dump())
    assert res.cannot_substitute is True
    assert res.suggestions == []


async def test_substitution_known_rule(provider: MockAIProvider) -> None:
    res = await provider.suggest(
        SubstitutionRequest(target_ingredient="mirin", recipe_title="x", pantry_items=["rice"])
    )
    assert res.cannot_substitute is False
    assert len(res.suggestions) == 1
    s = res.suggestions[0]
    assert s.requires_user_confirmation is True
    assert s.kind == "flavor_adaptation"


async def test_substitution_unknown_ingredient_cannot_substitute(
    provider: MockAIProvider,
) -> None:
    res = await provider.suggest(SubstitutionRequest(target_ingredient="saffron", recipe_title="x"))
    assert res.cannot_substitute is True


# --- coach --------------------------------------------------------------------------------


def coach_request(query: str, **overrides: object) -> CoachRequest:
    base = {
        "recipe_id": "r",
        "recipe_version_id": "v",
        "version_number": 1,
        "title": "Gochujang Chicken Thighs",
        "servings": 4,
        "current_step": step(),
        "session_revision": 7,
        "query": query,
    }
    base.update(overrides)
    return CoachRequest.model_validate(base)


async def test_coach_echoes_step_and_cues_with_grounding(provider: MockAIProvider) -> None:
    res = await provider.answer(coach_request("what now?"))
    CoachResponse.model_validate(res.model_dump())
    assert "Flip each piece" in res.answer_text
    assert "Glaze thickens" in res.answer_text
    assert {(g.type, g.id) for g in res.grounding} == {
        ("recipe_step", "step-5"),
        ("creator_note", "step-5"),
    }
    assert res.grounded_session_revision == 7
    assert res.proposed_action is None
    assert res.requires_confirmation is False
    assert res.safety_notice == "Do not judge doneness by color alone."


async def test_coach_never_certifies_doneness(provider: MockAIProvider) -> None:
    res = await provider.answer(coach_request("is the chicken done yet?"))
    assert res.safety_notice is not None
    assert "thermometer" in res.safety_notice.lower()


async def test_coach_includes_visual_observation_ref_only_when_given(
    provider: MockAIProvider,
) -> None:
    res = await provider.answer(coach_request("ok", visual_observation_id="obs-1"))
    assert ("visual_observation", "obs-1") in {(g.type, g.id) for g in res.grounding}


# --- observer -----------------------------------------------------------------------------


async def test_observer_is_uncertain_and_never_certifies_safety(provider: MockAIProvider) -> None:
    res = await provider.inspect(
        InspectRequest(
            session_id="s",
            grounded_revision=3,
            query="does this look right?",
            image_ref="frames/1.jpg",
            current_step=step(),
        )
    )
    InspectResponse.model_validate(res.model_dump())
    assert res.confidence == "medium"
    assert res.food_safety_certified is False
    assert res.grounded_revision == 3
    assert res.recommended_step_change is None
    assert res.limitations


def test_inspect_response_cannot_claim_food_safety() -> None:
    with pytest.raises(ValueError):
        InspectResponse(
            observation="x",
            step_alignment="y",
            confidence="high",
            grounded_revision=1,
            food_safety_certified=True,  # type: ignore[arg-type]
        )


# --- gemini stub + registry ---------------------------------------------------------------


async def test_gemini_stub_raises_provider_not_configured() -> None:
    provider = GeminiProvider(gemini_settings())
    assert isinstance(provider, AIProvider)
    with pytest.raises(ProviderNotConfigured):
        await provider.extract(ExtractionRequest(media_ref="x"))
    with pytest.raises(ProviderNotConfigured):
        await provider.observe(PantryObservationRequest(mode="transcript", transcript="x"))
    with pytest.raises(ProviderNotConfigured):
        await provider.suggest(SubstitutionRequest(target_ingredient="x", recipe_title="y"))
    with pytest.raises(ProviderNotConfigured):
        await provider.answer(coach_request("q"))
    with pytest.raises(ProviderNotConfigured):
        await provider.inspect(
            InspectRequest(
                session_id="s", grounded_revision=0, query="q", image_ref="i", current_step=step()
            )
        )


def test_registry_picks_by_env() -> None:
    assert isinstance(
        build_provider(mock_settings()),
        MockAIProvider,
    )
    assert isinstance(build_provider(gemini_settings()), GeminiProvider)


# --- gate probes --------------------------------------------------------------------------


@pytest.mark.parametrize("allergen", ["Peanut", "  peanut ", "PEANUT"])
async def test_substitution_declines_allergen_case_and_whitespace(
    provider: MockAIProvider, allergen: str
) -> None:
    res = await provider.suggest(
        SubstitutionRequest(
            target_ingredient="peanut",
            recipe_title="x",
            constraints=SubstitutionConstraints(allergies=[allergen]),
        )
    )
    assert res.cannot_substitute is True and res.suggestions == []


async def test_substitution_never_suggests_a_user_allergen(provider: MockAIProvider) -> None:
    # mirin's substitute is rice vinegar + sugar; a sugar/vinegar allergy must not be suggested
    res = await provider.suggest(
        SubstitutionRequest(
            target_ingredient="mirin",
            recipe_title="x",
            pantry_items=["rice vinegar", "sugar"],
            constraints=SubstitutionConstraints(allergies=["sugar"]),
        )
    )
    for s in res.suggestions:
        assert "sugar" not in json.dumps(s.model_dump()).lower()
    assert res.cannot_substitute is True and res.reason


@pytest.mark.parametrize("allergen", ["Vinegar", " rice vinegar ", "VINEGAR"])
async def test_substitution_declines_when_allergen_is_inside_candidate_phrase(
    provider: MockAIProvider, allergen: str
) -> None:
    res = await provider.suggest(
        SubstitutionRequest(
            target_ingredient="mirin",
            recipe_title="x",
            constraints=SubstitutionConstraints(allergies=[allergen]),
        )
    )
    assert res.cannot_substitute is True and res.suggestions == []


async def test_substitution_allergen_match_is_whole_word(provider: MockAIProvider) -> None:
    # "chi" is a substring of "chives" but not a whole word: must not block the swap.
    res = await provider.suggest(
        SubstitutionRequest(
            target_ingredient="scallion",
            recipe_title="x",
            constraints=SubstitutionConstraints(allergies=["chi"]),
        )
    )
    assert res.cannot_substitute is False


def test_food_safety_certified_cannot_be_true_even_via_validate() -> None:
    with pytest.raises(ValueError):
        InspectResponse.model_validate(
            {
                "observation": "x",
                "step_alignment": "y",
                "confidence": "high",
                "grounded_revision": 1,
                "food_safety_certified": True,
            }
        )
