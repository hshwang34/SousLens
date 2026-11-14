"""The capture interviewer's ask policy (brief 014). Pure: no I/O, no clock, no randomness.

Ported in spirit from Retrace's Expert Interviewer policy (ADR-0001): the interviewer (mock
rules or Gemini) *proposes* gaps and a question; this module *decides*. Every rule that keeps
the agent from nagging lives here, in code, not in a prompt:

* never while the creator is speaking (``silence_ms`` under the threshold), while Umma itself
  is speaking, while paused, after "stop asking", or while another question is open;
* at least 45 s between live questions (from the later of the last ask and its answer);
* at most 6 live questions per session, each expiring after 20 s;
* only for time-sensitive topics (temperature, time, quantity, doneness), only above the
  confidence floor, and never twice for one topic: gaps are deduped by ``topic_key`` and by
  word overlap, and a topic that was asked, answered or skipped is never asked live again.

Everything not asked live stays in the ledger; the wrap-up after Done asks at most 3 of the
still-open gaps (deferred ones first, then by topic importance, then oldest).

Time is ``t_ms``, milliseconds since the session started (the phone's clock), so tests and
replays are deterministic. The ledger is JSON (``capture_sessions.state_json``).
"""

from __future__ import annotations

import re
import unicodedata
from collections.abc import Iterable
from dataclasses import dataclass
from typing import Literal

from pydantic import BaseModel, Field

from app.ai.providers.base import CaptureTopic, GapDecision

GapStatus = Literal["open", "asked", "answered", "deferred", "dropped", "unanswered"]
Outcome = Literal["answered", "skipped", "later", "expired"]
Phase = Literal["live", "wrapup"]
Command = Literal["skip", "later", "stop_asking"]

# Importance order: the wrap-up picks from the top, and the mock proposes the first.
TOPIC_RANK: dict[str, int] = {
    "temperature": 0,
    "time": 1,
    "quantity": 2,
    "doneness": 3,
    "servings": 4,
    "prep": 5,
    "equipment": 6,
}
# Worth interrupting the cook for: asking later would lose it (DECISIONS #25).
LIVE_TOPICS = frozenset({"temperature", "time", "quantity", "doneness"})


@dataclass(frozen=True)
class PolicyConfig:
    silence_before_ask_ms: int = 1500
    min_ms_between_live_asks: int = 45_000
    max_live_asks: int = 6
    question_ttl_ms: int = 20_000
    confidence_floor: float = 0.7
    max_wrapup_questions: int = 3


DEFAULT_POLICY = PolicyConfig()


class Gap(BaseModel):
    topic_key: str
    topic: CaptureTopic
    question: str
    status: GapStatus = "open"
    first_seen_t_ms: int | None = None
    asked_count: int = 0
    question_id: str | None = None
    answer: str | None = None


class Question(BaseModel):
    question_id: str
    topic_key: str
    text: str
    phase: Phase
    asked_t_ms: int
    expires_at_ms: int | None = None
    outcome: Outcome | None = None
    closed_t_ms: int | None = None
    seq: int = 0  # ask order (JSONB does not keep dict order)


class Ledger(BaseModel):
    gaps: dict[str, Gap] = Field(default_factory=dict)
    questions: dict[str, Question] = Field(default_factory=dict)
    live_asks: int = 0
    last_ask_t_ms: int | None = None
    last_close_t_ms: int | None = None
    quiet: bool = False
    paused: bool = False
    pending_question_id: str | None = None
    # topic_keys the creator covered while cooking before any gap was raised for them.
    said: list[str] = Field(default_factory=list)
    # The last event ``seq`` the interviewer has already looked at (not ``t_ms``: two
    # utterances can share one).
    seen_seq: int = 0
    # The newest ``t_ms`` the phone has reported; client times are clamped against it.
    latest_t_ms: int = 0
    # One interviewer call at a time per session (server clock, epoch seconds), and a short
    # back-off (phone clock) after a failed call, so concurrent turns never multiply AI cost.
    interviewer_inflight_until: float | None = None
    interviewer_backoff_until_t_ms: int = 0

    @property
    def pending(self) -> Question | None:
        qid = self.pending_question_id
        return self.questions.get(qid) if qid else None


@dataclass(frozen=True)
class Ask:
    question_id: str
    topic_key: str
    topic: str
    text: str
    phase: Phase
    expires_at_ms: int | None


# --- normalisation + dedupe ---------------------------------------------------------------

_DUP_JACCARD = 0.6
_STOPWORDS = frozenset(
    "the a an is are what which how do does you your that this it it's its of to for on in "
    "and or there here any some be use using need should let put add much many long".split()
)


def normalize_topic_key(key: str | None) -> str:
    """lowercase snake_case ascii, ≤ 64 chars."""
    key = re.sub(r"[^a-z0-9]+", "_", (key or "").strip().lower())
    return key.strip("_")[:64]


def _tokens(text: str) -> set[str]:
    return {w for w in re.findall(r"[a-z0-9]+", text.lower()) if w not in _STOPWORDS and len(w) > 1}


def is_duplicate_question(question: str, existing: Iterable[str]) -> bool:
    q = _tokens(question)
    if not q:
        return False
    for other in existing:
        o = _tokens(other)
        if o and len(q & o) / len(q | o) >= _DUP_JACCARD:
            return True
    return False


# --- spoken commands ----------------------------------------------------------------------

_STOP_RE = re.compile(
    r"\b(stop asking|no more questions|stop the questions|quiet please|stop with the questions)\b"
)
_SKIP_RE = re.compile(r"^(skip|skip it|skip that|pass|next question|don't know|i don't know)$")
_LATER_RE = re.compile(r"^(later|ask me later|not now|later please|after)$")


def parse_command(text: str) -> Command | None:
    """A spoken "skip" / "later" / "stop asking". Skip and later must be the whole (short)
    utterance, so "don't skip the kimchi" is never a command."""
    norm = re.sub(r"[^a-z' ]+", " ", text.lower().replace(chr(0x2019), "'"))
    norm = re.sub(r"\s+", " ", norm).strip()
    norm = re.sub(r"^(umma |okay |ok |um |uh )+", "", norm).strip()
    if _STOP_RE.search(norm):
        return "stop_asking"
    if _SKIP_RE.match(norm):
        return "skip"
    if _LATER_RE.match(norm):
        return "later"
    return None


# --- ledger updates -----------------------------------------------------------------------


def merge_decision(ledger: Ledger, decision: GapDecision, *, t_ms: int | None) -> list[str]:
    """Fold one interviewer decision into the ledger; returns the new topic_keys. Fills first
    (the creator may have just said it), then new gaps, deduped by key and question words."""
    for raw in decision.filled_gaps:
        key = normalize_topic_key(raw)
        gap = ledger.gaps.get(key)
        if gap and gap.status in ("open", "asked", "deferred", "unanswered"):
            gap.status = "answered"
            gap.answer = gap.answer or "(said while cooking)"
        elif gap is None and key and key not in ledger.said:
            ledger.said = [*ledger.said, key][-200:]
    added: list[str] = []
    existing = [g.question for g in ledger.gaps.values()]
    for proposal in decision.open_gaps:
        key = normalize_topic_key(proposal.topic_key)
        known = key in ledger.gaps or key in ledger.said
        if not key or known or is_duplicate_question(proposal.question, existing):
            continue
        ledger.gaps[key] = Gap(
            topic_key=key,
            topic=proposal.topic,
            question=clean_question(proposal.question),
            first_seen_t_ms=t_ms,
        )
        existing.append(proposal.question)
        added.append(key)
    return added


QUESTION_MAX = 200
# How far past the newest known time a client-reported ``t_ms`` may run (a slow network).
T_MS_MARGIN = 60_000


def clean_question(text: str) -> str:
    """Model text is spoken and shown: no control or format characters, ≤ 200 chars."""
    kept = "".join(ch for ch in text if unicodedata.category(ch)[0] != "C" or ch == " ")
    return re.sub(r"\s+", " ", kept).strip()[:QUESTION_MAX]


def observe_time(ledger: Ledger, t_ms: int) -> None:
    ledger.latest_t_ms = max(ledger.latest_t_ms, t_ms)


def clamp_t_ms(ledger: Ledger, t_ms: int, *, floor: int = 0) -> int:
    """A client ``t_ms`` bounded to [floor, newest known + margin]."""
    return max(floor, min(t_ms, ledger.latest_t_ms + T_MS_MARGIN))


def resolve_outcome(
    ledger: Ledger, question_id: str, outcome: Outcome, t_ms: int
) -> tuple[Outcome, int]:
    """The outcome and time to record for a client report, whatever order calls arrive in:
    a live question reported after its ``expires_at_ms`` is ``expired``, exactly as if the
    next turn had expired it first."""
    question = ledger.questions[question_id]
    t = clamp_t_ms(ledger, t_ms, floor=question.asked_t_ms)
    if question.expires_at_ms is not None and t > question.expires_at_ms:
        return "expired", question.expires_at_ms
    return outcome, t


def expire_pending(ledger: Ledger, now_ms: int) -> str | None:
    """Close the open live question if its 20 s are up. Returns its id, if it expired."""
    pending = ledger.pending
    if pending is None or pending.expires_at_ms is None or now_ms < pending.expires_at_ms:
        return None
    apply_outcome(ledger, pending.question_id, "expired", None, now_ms)
    return pending.question_id


def apply_outcome(
    ledger: Ledger, question_id: str, outcome: Outcome, answer: str | None, t_ms: int
) -> Question:
    """answered → closed for good; skipped → dropped; later → deferred to the wrap-up (in the
    wrap-up itself, later is a skip); expired → stays eligible for one wrap-up ask."""
    question = ledger.questions.get(question_id)
    if question is None:
        raise KeyError(question_id)
    if question.outcome is not None:
        raise ValueError("question already closed")
    question.outcome = outcome
    question.closed_t_ms = t_ms
    gap = ledger.gaps.get(question.topic_key)
    if gap is not None:
        if outcome == "answered":
            gap.status = "answered"
            gap.answer = (answer or "").strip() or None
        elif outcome == "skipped" or (outcome == "later" and question.phase == "wrapup"):
            gap.status = "dropped"
        elif outcome == "later":
            gap.status = "deferred"
        else:
            gap.status = "unanswered"
    if ledger.pending_question_id == question_id:
        ledger.pending_question_id = None
    if question.phase == "live":
        ledger.last_close_t_ms = max(t_ms, ledger.last_close_t_ms or 0)
    return question


# --- decisions ----------------------------------------------------------------------------


def gate_open(
    ledger: Ledger,
    *,
    recording: bool,
    now_ms: int,
    silence_ms: int,
    assistant_speaking: bool,
    config: PolicyConfig = DEFAULT_POLICY,
) -> bool:
    """Could a live question be asked right now, whatever the topic? Checked before the
    interviewer is even called, so a creator mid-sentence never costs an AI call."""
    if not recording or ledger.paused or ledger.quiet or ledger.pending is not None:
        return False
    if assistant_speaking or silence_ms < config.silence_before_ask_ms:
        return False
    if ledger.live_asks >= config.max_live_asks:
        return False
    last = max(ledger.last_ask_t_ms or -(10**12), ledger.last_close_t_ms or -(10**12))
    return now_ms - last >= config.min_ms_between_live_asks


def decide_live_ask(
    ledger: Ledger,
    decision: GapDecision,
    *,
    question_id: str,
    recording: bool,
    now_ms: int,
    silence_ms: int,
    assistant_speaking: bool,
    config: PolicyConfig = DEFAULT_POLICY,
) -> Ask | None:
    """Approve or veto the proposal. Every rule is a hard gate; a veto never loses the gap."""
    if not gate_open(
        ledger,
        recording=recording,
        now_ms=now_ms,
        silence_ms=silence_ms,
        assistant_speaking=assistant_speaking,
        config=config,
    ):
        return None
    if decision.confidence < config.confidence_floor:
        return None
    gap = ledger.gaps.get(normalize_topic_key(decision.topic_key))
    if gap is None or gap.status != "open" or gap.asked_count > 0:
        return None
    if gap.topic not in LIVE_TOPICS:
        return None  # not worth interrupting for: it waits for the wrap-up
    asked = [q.text for q in ledger.questions.values()]
    if is_duplicate_question(gap.question, asked):
        gap.status = "dropped"
        return None
    expires = now_ms + config.question_ttl_ms
    _mark_asked(ledger, gap, question_id, "live", now_ms, expires)
    ledger.live_asks += 1
    ledger.last_ask_t_ms = now_ms
    ledger.pending_question_id = question_id
    return Ask(question_id, gap.topic_key, gap.topic, gap.question, "live", expires)


def wrapup_candidates(ledger: Ledger) -> list[Gap]:
    """Still-open gaps in wrap-up order: deferred first, then topic importance, then oldest.
    Answered and skipped topics never come back; a topic gets at most two asks in total."""
    eligible = [
        g
        for g in ledger.gaps.values()
        if g.status in ("open", "deferred", "unanswered") and g.asked_count < 2
    ]
    eligible.sort(
        key=lambda g: (
            0 if g.status == "deferred" else 1,
            TOPIC_RANK.get(g.topic, 9),
            g.first_seen_t_ms if g.first_seen_t_ms is not None else 10**12,
            g.topic_key,
        )
    )
    return eligible


def pick_wrapup_questions(
    ledger: Ledger,
    question_ids: Iterable[str],
    *,
    now_ms: int,
    config: PolicyConfig = DEFAULT_POLICY,
) -> list[Ask]:
    ids = iter(question_ids)
    asks: list[Ask] = []
    ledger.pending_question_id = None
    for gap in wrapup_candidates(ledger)[: config.max_wrapup_questions]:
        qid = next(ids)
        _mark_asked(ledger, gap, qid, "wrapup", now_ms, None)
        asks.append(Ask(qid, gap.topic_key, gap.topic, gap.question, "wrapup", None))
    return asks


def open_wrapup_questions(ledger: Ledger) -> list[Ask]:
    out: list[Ask] = []
    for q in sorted(ledger.questions.values(), key=lambda q: q.seq):
        if q.phase == "wrapup" and q.outcome is None:
            gap = ledger.gaps.get(q.topic_key)
            topic = gap.topic if gap else "time"
            out.append(Ask(q.question_id, q.topic_key, topic, q.text, "wrapup", None))
    return out


def _mark_asked(
    ledger: Ledger, gap: Gap, qid: str, phase: Phase, now_ms: int, expires: int | None
) -> None:
    gap.status = "asked"
    gap.asked_count += 1
    gap.question_id = qid
    ledger.questions[qid] = Question(
        question_id=qid,
        topic_key=gap.topic_key,
        text=gap.question,
        phase=phase,
        asked_t_ms=now_ms,
        expires_at_ms=expires,
        seq=len(ledger.questions),
    )
