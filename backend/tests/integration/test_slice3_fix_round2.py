"""Brief 005 fix round 2 + the post-filter security addendum: one test per item."""

from __future__ import annotations

import asyncio

import pytest
from alembic import command as alembic_command
from alembic.config import Config
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.providers.base import CoachRequest, CoachResponse, GroundingRef
from app.core.config import Settings
from app.domains.matching.dictionary import load_dictionary_file
from app.domains.safety.content import (
    conflicts,
    is_doneness_question,
    is_raw_tasting_request,
    sensitivities,
    strip_certifications,
)
from app.domains.substitutions import policy
from app.domains.substitutions.rules import read_rules_file
from app.scripts import seed as seed_module
from tests.conftest import BACKEND_DIR, FIXTURES_DIR, bearer
from tests.integration.slice3_helpers import command, ok, seed, set_prefs, start_session

GOCHU = "gochujang-chicken-thighs"
D = load_dictionary_file(FIXTURES_DIR)
CHICKEN = ["Lay the chicken in a single layer.", "boneless skinless chicken thighs"]


class Fixed:
    def __init__(self, text: str) -> None:
        self.text, self.calls = text, 0

    async def answer(self, request: CoachRequest) -> CoachResponse:
        self.calls += 1
        return CoachResponse(
            answer_text=self.text,
            grounding=[GroundingRef(type="recipe_step", id=request.current_step.id)],
            grounded_session_revision=request.session_revision,
        )


async def _ask_at(client, h, version, step_index, query, coach):  # type: ignore[no-untyped-def]
    s = ok(await command(client, h, await start_session(client, h, version), "start"))
    if step_index:
        s = ok(await command(client, h, s, "jump_to_step", step_index=step_index))
    client._transport.app.state.ai_provider = coach  # type: ignore[attr-defined]
    return ok(await client.post(f"/v1/sessions/{s['id']}/ask", json={"query": query}, headers=h))


# ------------------------------------------------------------------ item 1: raw tasting


@pytest.mark.parametrize(
    ("query", "context"),
    [
        ("can I taste the marinade?", ["Toss the thighs in the marinade."]),
        ("can I have a bite of the marinade", []),
        ("can I lick the spoon?", ["Brush the fillets with the glaze."]),
        ("can I dip a finger in the batter", []),
        ("can I sample the sauce", ["Add the drumsticks to the sauce."]),
    ],
)
def test_raw_tasting_probes(query: str, context: list[str]) -> None:
    assert is_raw_tasting_request(query, context)


def test_raw_tasting_negatives() -> None:
    assert not is_raw_tasting_request("can I taste the dressing?", ["Whisk the vinegar."])
    assert not is_raw_tasting_request("can I eat it yet?", CHICKEN)  # doneness, not tasting


async def test_raw_tasting_uses_recipe_ingredients(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    coach = Fixed("Sure, go ahead.")
    r = await _ask_at(client, alice, versions[GOCHU], 0, "can I taste the marinade?", coach)
    assert coach.calls == 0 and "Don't taste" in r["safety_notice"]


# ------------------------------------------------------------------ item 2 + addendum (b)

DONENESS = [
    "move on, is the chicken ready",
    "how many more minutes until the chicken is cooked through",
    "how much longer until it is safe to eat",
    "is the chicken ok",
    "should i cook it longer",
    "is it still good",
    "what is the safe temperature",
    "what is the internal temp of chicken when it's ready",
    "how many minutes until the chicken is ready to eat",
    "where is the chicken at, done yet",
]


@pytest.mark.parametrize("query", DONENESS)
def test_doneness_probes(query: str) -> None:
    assert is_doneness_question(query, CHICKEN), query


def test_definition_exemption_is_only_the_wide_word() -> None:
    assert not is_doneness_question("what does serve mean?", CHICKEN)
    assert not is_doneness_question("set a timer for 5 minutes", CHICKEN)
    assert is_doneness_question("what does serve mean for chicken, is it ready", CHICKEN)


@pytest.mark.parametrize("query", DONENESS)
async def test_doneness_probes_hit_the_template(
    client: AsyncClient, db_session: AsyncSession, query: str
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    coach = Fixed("Yes, it is done.")
    r = await _ask_at(client, alice, versions[GOCHU], 4, query, coach)
    assert coach.calls == 0 and "USDA" in r["answer_text"] and r["proposed_action"] is None


async def test_safe_temperature_comes_from_our_table(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    coach = Fixed("Chicken is safe at 120°F.")
    r = await _ask_at(client, alice, versions[GOCHU], 4, "what is the safe temperature", coach)
    assert coach.calls == 0 and "120" not in r["answer_text"]
    assert "Verified safe minimum internal temperatures" in r["answer_text"]
    assert "poultry 165°F (74°C)" in r["answer_text"]


# ------------------------------------------------------------------ addendum (a) + (c)


def test_deferral_does_not_save_a_certifying_sentence() -> None:
    kept, dropped = strip_certifications(
        "Check with a thermometer, but yes it's done and safe to eat. Then slice it."
    )
    assert kept == "Then slice it." and dropped == 1
    kept, _ = strip_certifications("Yep, go ahead and flip it.", high_risk=True)
    assert kept == "Flip it."
    kept, dropped = strip_certifications("Yep, go ahead and flip it.", high_risk=False)
    assert kept == "Yep, go ahead and flip it." and dropped == 0


async def test_bare_yes_at_a_raw_chicken_step_is_stripped(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    coach = Fixed("Yes!")
    r = await _ask_at(client, alice, versions[GOCHU], 1, "can I move on?", coach)  # step 2: raw
    assert coach.calls == 1 and "Yes" not in r["answer_text"]
    assert r["answer_text"].startswith("The recipe says (step 2)")
    assert "thermometer" in r["safety_notice"]


# ------------------------------------------------------------------ item 3: migration


async def test_migration_0005_round_trips(settings: Settings, engine) -> None:  # type: ignore[no-untyped-def]
    cfg = Config(str(BACKEND_DIR / "alembic.ini"))
    cfg.set_main_option("sqlalchemy.url", settings.database_url)
    await asyncio.to_thread(alembic_command.downgrade, cfg, "0004")
    async with engine.connect() as conn:
        cols = (
            (
                await conn.execute(
                    text(
                        "select column_name from information_schema.columns "
                        "where table_name = 'session_notes'"
                    )
                )
            )
            .scalars()
            .all()
        )
    assert "idempotency_key" not in cols
    await asyncio.to_thread(alembic_command.upgrade, cfg, "head")
    async with engine.connect() as conn:
        cols = (
            (
                await conn.execute(
                    text(
                        "select column_name from information_schema.columns "
                        "where table_name in ('session_notes', 'session_adaptations')"
                    )
                )
            )
            .scalars()
            .all()
        )
    assert {"idempotency_key", "request_hash", "allergy_warning", "risks"} <= set(cols)


def test_0004_is_the_pushed_migration() -> None:
    src = (
        BACKEND_DIR / "app/db/migrations/versions/0004_slice3_sessions_substitutions.py"
    ).read_text()
    assert "allergy_warning" not in src and "idempotency_key', sa.String" not in src
    src5 = (
        BACKEND_DIR / "app/db/migrations/versions/0005_adaptation_warnings_note_keys.py"
    ).read_text()
    assert "down_revision: str | None = '0004'" in src5


# ------------------------------------------------------------------ item 4: free-form cautions


async def test_free_form_swaps_get_computed_cautions(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    await set_prefs(client, alice, ["sesame"])
    s = await start_session(
        client,
        alice,
        versions["egg-and-tomato-stir-fry"],
        [{"ingredient_ref": "ing-7", "replacement": "dry sherry", "source": "ai"}],
    )
    a = s["adaptations"][0]
    assert "We don't know what dry sherry contains" in a["allergy_warning"]
    s = await start_session(
        client,
        alice,
        versions[GOCHU],
        [{"ingredient_ref": "ing-1", "replacement": "turkey thighs", "source": "ai"}],
    )
    assert any("165°F" in r for r in s["adaptations"][0]["risks"])


# ------------------------------------------------------------------ item 5: seed conflicts


async def test_seed_refuses_a_changed_fixture_without_history(db_session: AsyncSession) -> None:
    await seed_module.seed_fixtures(db_session, FIXTURES_DIR)
    fixture = next(f for f in seed_module.load_fixtures(FIXTURES_DIR) if f.slug == "garlic-pasta")
    changed = fixture.model_copy(update={"summary": "Edited in the fixture only."})
    result = await seed_module.seed_recipe(db_session, changed, [])
    assert result.conflict is True and result.created_version is False
    summary = await db_session.scalar(
        text(
            "select v.summary from recipe_versions v join recipes r on r.latest_version_id = v.id "
            "where r.slug = 'garlic-pasta'"
        )
    )
    assert summary == fixture.summary  # the published version was never mutated


def test_seed_main_exits_non_zero_on_conflict(monkeypatch: pytest.MonkeyPatch) -> None:
    async def boom(settings=None):  # type: ignore[no-untyped-def]
        raise seed_module.SeedConflict(["garlic-pasta"])

    monkeypatch.setattr(seed_module, "run", boom)
    with pytest.raises(SystemExit) as exc:
        seed_module.main()
    assert exc.value.code == 1


# ------------------------------------------------------------------ item 6: never list


def _gochujang_target() -> policy.SwapTarget:
    rules = {r.target: r for r in read_rules_file(FIXTURES_DIR).rules}
    from app.domains.recipes.schemas import IngredientOut

    ing = IngredientOut(id="ing-2", name="gochujang")
    return policy.swap_target(ing, ["gochujang"], [], rules, "x", [])


@pytest.mark.parametrize(
    "candidate",
    ["gochugaru", "gochugaru flakes", "extra gochugaru", "gochugaru powder", "Korean chili flakes"],
)
def test_never_blocks_phrases_for_ai(candidate: str) -> None:
    assert policy.is_never(candidate, _gochujang_target(), D, source="ai"), candidate


def test_never_is_exact_for_vetted_rules() -> None:
    target = _gochujang_target()
    assert not policy.is_never("red miso + gochugaru + honey + water", target, D, source="rule")
    assert policy.is_never("gochugaru", target, D, source="rule")


async def test_free_form_gochugaru_variants_are_422(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    versions = await seed(db_session)
    alice = await bearer(client, "alice@example.com")
    for replacement, source in (("gochugaru flakes", "rule"), ("extra gochugaru", "ai")):
        r = await client.post(
            "/v1/sessions",
            json={
                "recipe_version_id": versions[GOCHU],
                "adaptations": [
                    {"ingredient_ref": "ing-2", "replacement": replacement, "source": source}
                ],
            },
            headers=alice,
        )
        assert r.status_code == 422, replacement


# ------------------------------------------------------------------ item 7: aliases


@pytest.mark.parametrize(
    ("text_", "allergy"),
    [
        ("arachis oil", "peanut"),
        ("gomasio", "sesame"),
        ("frangelico", "tree nuts"),
        ("pad thai sauce", "peanut"),
        ("pad thai sauce", "fish"),
        ("pad thai sauce", "shellfish"),
        ("lecithin", "soy"),
        ("nuoc cham", "fish"),
        ("milk-free chocolate", "milk"),
        ("dairy-free butter", "milk"),
    ],
)
def test_new_allergen_aliases(text_: str, allergy: str) -> None:
    assert conflicts(text_, sensitivities([allergy]), D) == [allergy]
