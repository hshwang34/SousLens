"""The capture ask policy (brief 014), ported from Retrace's tests/test_interview_policy.py and
adapted to recipe topics: budget, spacing, silence gate, confidence floor, live topics, dedupe,
quiet / pause / pending exclusivity, outcomes, spoken commands and wrap-up ordering."""

from __future__ import annotations

import pytest

from app.ai.providers.base import GapDecision, GapProposal
from app.domains.capture import policy
from app.domains.capture.policy import DEFAULT_POLICY, Ledger


def _gap(key="simmer_time", topic="time", q="How long do you let it simmer?"):
    return GapProposal(topic_key=key, topic=topic, question=q)


def _decision(propose=None, conf=0.9, gaps=(), filled=()):
    return GapDecision(
        open_gaps=list(gaps),
        filled_gaps=list(filled),
        topic_key=propose,
        proposed_question=None,
        confidence=conf,
    )


def _decide(
    ledger, decision, *, now=100_000, silence=2000, speaking=False, recording=True, qid="q1"
):
    return policy.decide_live_ask(
        ledger,
        decision,
        question_id=qid,
        recording=recording,
        now_ms=now,
        silence_ms=silence,
        assistant_speaking=speaking,
    )


@pytest.fixture
def ledger() -> Ledger:
    led = Ledger()
    policy.merge_decision(led, _decision(gaps=[_gap()]), t_ms=10_000)
    return led


# --- normalisation + dedupe ----------------------------------------------------------------


def test_normalize_topic_key() -> None:
    assert policy.normalize_topic_key(" Simmer-Time! ") == "simmer_time"
    assert policy.normalize_topic_key("") == ""
    assert policy.normalize_topic_key(None) == ""


def test_duplicate_question_by_words() -> None:
    assert policy.is_duplicate_question(
        "How long do you simmer the stew?", ["How long should the stew simmer?"]
    )
    assert not policy.is_duplicate_question(
        "How long do you let it simmer?", ["How much tofu do you use?"]
    )


def test_merge_dedupes_by_key_and_text() -> None:
    led = Ledger()
    assert policy.merge_decision(led, _decision(gaps=[_gap()]), t_ms=10_000) == ["simmer_time"]
    again = _decision(
        gaps=[_gap(), _gap(key="stew_simmer_duration", q="How long do you simmer it for?")]
    )
    assert policy.merge_decision(led, again, t_ms=12_000) == []
    assert len(led.gaps) == 1
    assert led.gaps["simmer_time"].first_seen_t_ms == 10_000


def test_merge_marks_filled_from_speech(ledger: Ledger) -> None:
    policy.merge_decision(ledger, _decision(filled=["simmer_time"]), t_ms=15_000)
    assert ledger.gaps["simmer_time"].status == "answered"


def test_said_while_cooking_is_never_a_gap_later() -> None:
    led = Ledger()
    policy.merge_decision(led, _decision(filled=["kimchi_quantity"]), t_ms=1)
    gap = _gap("kimchi_quantity", "quantity", "How much kimchi do you use?")
    assert policy.merge_decision(led, _decision(gaps=[gap]), t_ms=2) == []
    assert led.said == ["kimchi_quantity"]


def test_ledger_round_trips_as_json(ledger: Ledger) -> None:
    _decide(ledger, _decision(propose="simmer_time"))
    again = Ledger.model_validate(ledger.model_dump(mode="json"))
    assert again == ledger
    assert again.pending is not None


# --- live gates ----------------------------------------------------------------------------


def test_happy_path_approves_and_updates_ledger(ledger: Ledger) -> None:
    ask = _decide(ledger, _decision(propose="simmer_time"))
    assert ask is not None
    assert ask.topic_key == "simmer_time"
    assert ask.text == "How long do you let it simmer?"
    assert ask.expires_at_ms == 100_000 + DEFAULT_POLICY.question_ttl_ms
    assert ledger.gaps["simmer_time"].status == "asked"
    assert ledger.live_asks == 1
    assert ledger.pending_question_id == "q1"


def test_silence_threshold_and_assistant_speaking(ledger: Ledger) -> None:
    d = _decision(propose="simmer_time")
    assert _decide(ledger, d, silence=DEFAULT_POLICY.silence_before_ask_ms - 1) is None
    assert _decide(ledger, d, speaking=True) is None
    assert ledger.gaps["simmer_time"].status == "open"
    assert _decide(ledger, d, silence=DEFAULT_POLICY.silence_before_ask_ms) is not None


def test_confidence_floor_keeps_gap(ledger: Ledger) -> None:
    assert _decide(ledger, _decision(propose="simmer_time", conf=0.69)) is None
    assert ledger.gaps["simmer_time"].status == "open"


def test_wrapup_only_topics_never_asked_live() -> None:
    led = Ledger()
    gap = _gap(key="servings", topic="servings", q="How many people does this feed?")
    policy.merge_decision(led, _decision(gaps=[gap]), t_ms=1)
    assert _decide(led, _decision(propose="servings")) is None
    assert led.gaps["servings"].status == "open"


def test_max_live_asks() -> None:
    led = Ledger(live_asks=DEFAULT_POLICY.max_live_asks)
    policy.merge_decision(led, _decision(gaps=[_gap()]), t_ms=1)
    assert _decide(led, _decision(propose="simmer_time")) is None


def test_spacing_from_last_ask_and_close(ledger: Ledger) -> None:
    gap = DEFAULT_POLICY.min_ms_between_live_asks
    ledger.last_ask_t_ms = 100_000 - gap + 1
    assert _decide(ledger, _decision(propose="simmer_time")) is None
    ledger.last_ask_t_ms = 100_000 - gap
    ledger.last_close_t_ms = 100_000 - gap + 5
    assert _decide(ledger, _decision(propose="simmer_time")) is None
    ledger.last_close_t_ms = 100_000 - gap
    assert _decide(ledger, _decision(propose="simmer_time")) is not None


def test_quiet_paused_pending_and_not_recording(ledger: Ledger) -> None:
    d = _decision(propose="simmer_time")
    assert _decide(ledger, d, recording=False) is None
    ledger.quiet = True
    assert _decide(ledger, d) is None
    ledger.quiet, ledger.paused = False, True
    assert _decide(ledger, d) is None
    ledger.paused = False
    policy.merge_decision(
        ledger,
        _decision(gaps=[_gap("oven_temperature", "temperature", "What temperature is the oven?")]),
        t_ms=1,
    )
    assert _decide(ledger, _decision(propose="oven_temperature"), qid="q0") is not None
    assert _decide(ledger, d, now=500_000) is None  # q0 is still open


def test_never_reasks_live(ledger: Ledger) -> None:
    assert _decide(ledger, _decision(propose="simmer_time")) is not None
    policy.apply_outcome(ledger, "q1", "expired", None, 120_000)
    assert _decide(ledger, _decision(propose="simmer_time"), now=900_000, qid="q2") is None


def test_unknown_or_unproposed_key(ledger: Ledger) -> None:
    assert _decide(ledger, _decision(propose="nope")) is None
    assert _decide(ledger, _decision(propose=None)) is None


# --- outcomes + expiry ---------------------------------------------------------------------


@pytest.mark.parametrize(
    ("outcome", "status"),
    [
        ("answered", "answered"),
        ("skipped", "dropped"),
        ("later", "deferred"),
        ("expired", "unanswered"),
    ],
)
def test_outcomes(ledger: Ledger, outcome: policy.Outcome, status: str) -> None:
    _decide(ledger, _decision(propose="simmer_time"))
    policy.apply_outcome(ledger, "q1", outcome, "about fifteen minutes", 105_000)
    assert ledger.gaps["simmer_time"].status == status
    assert ledger.pending_question_id is None
    assert ledger.last_close_t_ms == 105_000
    with pytest.raises(ValueError):
        policy.apply_outcome(ledger, "q1", "answered", "x", 106_000)
    with pytest.raises(KeyError):
        policy.apply_outcome(ledger, "nope", "answered", "x", 106_000)


def test_expire_pending_after_ttl(ledger: Ledger) -> None:
    _decide(ledger, _decision(propose="simmer_time"))
    assert policy.expire_pending(ledger, 100_000 + DEFAULT_POLICY.question_ttl_ms - 1) is None
    assert policy.expire_pending(ledger, 100_000 + DEFAULT_POLICY.question_ttl_ms) == "q1"
    assert ledger.gaps["simmer_time"].status == "unanswered"


def test_late_report_is_expired_and_time_is_clamped(ledger: Ledger) -> None:
    _decide(ledger, _decision(propose="simmer_time"))  # asked at 100 000, expires 120 000
    policy.observe_time(ledger, 100_000)
    assert policy.resolve_outcome(ledger, "q1", "answered", 119_999) == ("answered", 119_999)
    assert policy.resolve_outcome(ledger, "q1", "answered", 120_001) == ("expired", 120_000)
    assert policy.resolve_outcome(ledger, "q1", "skipped", 10**9) == ("expired", 120_000)
    assert policy.resolve_outcome(ledger, "q1", "answered", 5) == ("answered", 100_000)


def test_wrapup_reports_are_clamped_not_expired() -> None:
    led = Ledger(latest_t_ms=1_000)
    policy.merge_decision(led, _decision(gaps=[_gap()]), t_ms=1)
    policy.pick_wrapup_questions(led, ["w1"], now_ms=1_000)
    assert policy.resolve_outcome(led, "w1", "answered", 10**9) == (
        "answered",
        1_000 + policy.T_MS_MARGIN,
    )


def test_model_question_text_is_cleaned() -> None:
    led = Ledger()
    gap = _gap(q="How long\u202e do you\x00 let it\n simmer?")
    policy.merge_decision(led, _decision(gaps=[gap]), t_ms=1)
    assert led.gaps["simmer_time"].question == "How long do you let it simmer?"
    assert len(policy.clean_question("x" * 500)) == policy.QUESTION_MAX


# --- spoken commands -----------------------------------------------------------------------


@pytest.mark.parametrize(
    ("text", "command"),
    [
        ("Skip", "skip"),
        ("skip it.", "skip"),
        ("Later", "later"),
        ("ask me later", "later"),
        ("Okay, stop asking.", "stop_asking"),
        ("no more questions please", "stop_asking"),
        ("don't skip the kimchi", None),
        ("I'll add the tofu later", None),
        ("now the onions", None),
    ],
)
def test_parse_command(text: str, command: str | None) -> None:
    assert policy.parse_command(text) == command


# --- wrap-up -------------------------------------------------------------------------------


def test_wrapup_order_deferred_first_then_importance() -> None:
    led = Ledger()
    policy.merge_decision(
        led,
        _decision(
            gaps=[
                _gap("tofu_quantity", "quantity", "How much tofu do you use?"),
                _gap("servings", "servings", "How many people does this feed?"),
                _gap("oven_temperature", "temperature", "What temperature is the oven?"),
                _gap("answered_one", "time", "How long do you rest the dough?"),
                _gap("skipped_one", "doneness", "How do you know the pork is browned?"),
                _gap("pot_size", "equipment", "What size pot do you use?"),
            ]
        ),
        t_ms=1,
    )
    led.gaps["answered_one"].status = "answered"
    led.gaps["skipped_one"].status = "dropped"
    led.gaps["pot_size"].status = "deferred"
    asks = policy.pick_wrapup_questions(led, ["w1", "w2", "w3", "w4"], now_ms=1_000_000)
    assert [a.topic_key for a in asks] == ["pot_size", "oven_temperature", "tofu_quantity"]
    assert all(a.phase == "wrapup" and a.expires_at_ms is None for a in asks)
    assert [a.topic_key for a in policy.open_wrapup_questions(led)] == [
        "pot_size",
        "oven_temperature",
        "tofu_quantity",
    ]
    # In the wrap-up "later" is a skip; it never comes back.
    policy.apply_outcome(led, "w1", "later", None, 1_000_100)
    assert led.gaps["pot_size"].status == "dropped"


def test_wrapup_max_three_and_two_asks_per_topic() -> None:
    led = Ledger()
    foods = ["tofu", "onion", "garlic", "kimchi", "pork", "scallion", "sugar", "water"]
    policy.merge_decision(
        led,
        _decision(
            gaps=[_gap(f"k{i}", "quantity", f"How much {f} goes in?") for i, f in enumerate(foods)]
        ),
        t_ms=1,
    )
    assert len(led.gaps) == 8
    assert len(policy.pick_wrapup_questions(led, map(str, range(10)), now_ms=5)) == 3
    led.gaps["k7"].status, led.gaps["k7"].asked_count = "unanswered", 1
    led.gaps["k6"].status, led.gaps["k6"].asked_count = "unanswered", 2
    keys = {g.topic_key for g in policy.wrapup_candidates(led)}
    assert "k7" in keys
    assert "k6" not in keys
