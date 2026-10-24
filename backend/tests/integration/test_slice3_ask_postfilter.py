"""Security review of bab9b53: every model answer is post-filtered for doneness / safety claims,
and the definition exemption never overrides a strict doneness word."""

from __future__ import annotations

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.providers.base import CoachRequest, CoachResponse, GroundingRef
from app.domains.safety.content import is_doneness_question, strip_certifications
from tests.conftest import bearer
from tests.integration.slice3_helpers import command, ok, seed, start_session

GOCHU = "gochujang-chicken-thighs"
SALAD = "cucumber-salad"


class Fixed:
    def __init__(self, text: str) -> None:
        self.text = text
        self.calls = 0

    async def answer(self, request: CoachRequest) -> CoachResponse:
        self.calls += 1
        return CoachResponse(
            answer_text=self.text,
            grounding=[GroundingRef(type="recipe_step", id=request.current_step.id)],
            grounded_session_revision=request.session_revision,
            uncertainty="low",
        )


async def _ask(client: AsyncClient, h: dict, version: str, query: str, coach: Fixed) -> dict:
    s = ok(await command(client, h, await start_session(client, h, version), "start"))
    client._transport.app.state.ai_provider = coach  # type: ignore[attr-defined]
    return ok(await client.post(f"/v1/sessions/{s['id']}/ask", json={"query": query}, headers=h))


async def test_certifying_model_answer_to_an_innocent_query_is_stripped(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    coach = Fixed("Yes, it's fully cooked and safe to eat. Keep tossing the pieces.")
    r = await _ask(client, alice, versions[GOCHU], "what should I do with the pan now?", coach)
    assert coach.calls == 1  # not caught by the detectors: the model answered
    assert "fully cooked" not in r["answer_text"] and "safe to eat" not in r["answer_text"]
    assert r["answer_text"] == "Keep tossing the pieces."
    assert "thermometer" in r["safety_notice"] and r["uncertainty"] != "low"


async def test_an_answer_that_is_only_a_verdict_falls_back_to_the_template(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    r = await _ask(client, alice, versions[GOCHU], "thoughts?", Fixed("Yes! It looks done."))
    assert r["answer_text"].startswith("The recipe says (step 1):")
    assert "I can't tell from a description or photo" in r["answer_text"]
    assert "thermometer" in r["safety_notice"]


async def test_definition_opener_never_overrides_a_strict_word(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    coach = Fixed("It is done.")
    query = "what does 'done' mean, is my chicken done?"
    assert is_doneness_question(query, ["chicken"])
    r = await _ask(client, alice, versions[GOCHU], query, coach)
    assert coach.calls == 0 and "USDA" in r["answer_text"]
    assert not is_doneness_question("what does finely minced mean?", ["chicken"])


async def test_benign_answer_passes_through_unchanged(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    text = "The recipe says (step 1): rinse the cucumbers. My suggestion: trim both ends first."
    r = await _ask(client, alice, versions[SALAD], "what should I do first?", Fixed(text))
    assert r["answer_text"] == text and r["safety_notice"] is None


def test_strip_certifications_keeps_deferrals() -> None:
    kept, dropped = strip_certifications(
        "It should be ready now. Check it with an instant-read thermometer. Serve with rice."
    )
    assert kept == "Check it with an instant-read thermometer. Serve with rice." and dropped == 1
