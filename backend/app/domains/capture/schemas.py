"""Wire shapes for ``/v1/capture`` (brief 014, ``docs/product/briefs/014-api-contract.md``)."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

from app.domains.capture.policy import DEFAULT_POLICY

MAX_T_MS = 4 * 60 * 60 * 1000  # a session is at most 4 hours of phone time
MAX_SEGMENTS = 50
TEXT_MAX = 2000

SpokenText = Annotated[str, StringConstraints(strip_whitespace=True, max_length=TEXT_MAX)]
TMs = Annotated[int, Field(ge=0, le=MAX_T_MS)]


class _In(BaseModel):
    model_config = ConfigDict(extra="forbid")


class SessionCreateIn(_In):
    mode: Literal["voice", "camera"] = "voice"
    title_hint: Annotated[str, StringConstraints(strip_whitespace=True, max_length=120)] | None = (
        None
    )


class SegmentIn(_In):
    t_ms: TMs
    text: SpokenText
    is_final: bool = True


class TurnsIn(_In):
    """A batch of transcript segments. Only final segments are stored (partials are for the
    live captions only). ``t_ms`` is "now" on the phone; it defaults to the newest segment."""

    segments: list[SegmentIn] = Field(default_factory=list, max_length=MAX_SEGMENTS)
    silence_ms: int = Field(ge=0, le=MAX_T_MS)
    assistant_speaking: bool = False
    t_ms: TMs | None = None


class QuestionOutcomeIn(_In):
    outcome: Literal["answered", "skipped", "later", "expired"]
    answer_text: SpokenText | None = None
    t_ms: TMs


class CommandIn(_In):
    command: Literal["stop_asking", "pause", "resume"]
    t_ms: TMs | None = None


class AskOut(BaseModel):
    question_id: uuid.UUID
    text: str
    topic_key: str
    topic: str
    phase: Literal["live", "wrapup"]
    expires_at_ms: int | None


class TurnsOut(BaseModel):
    ask: AskOut | None
    stored: int
    closed_question_id: uuid.UUID | None = None
    asking_stopped: bool


class QuestionOutcomeOut(BaseModel):
    question_id: uuid.UUID
    topic_key: str
    outcome: str


class EventOut(BaseModel):
    id: uuid.UUID
    t_ms: int
    kind: str
    text: str
    topic_key: str | None
    question_id: uuid.UUID | None


class PolicyOut(BaseModel):
    """Mirrored to the phone so its pause gate and the server agree."""

    silence_before_ask_ms: int = DEFAULT_POLICY.silence_before_ask_ms
    min_ms_between_live_asks: int = DEFAULT_POLICY.min_ms_between_live_asks
    max_live_asks: int = DEFAULT_POLICY.max_live_asks
    question_ttl_ms: int = DEFAULT_POLICY.question_ttl_ms
    max_wrapup_questions: int = DEFAULT_POLICY.max_wrapup_questions


class SessionOut(BaseModel):
    id: uuid.UUID
    mode: str
    status: str
    title_hint: str | None
    draft_id: uuid.UUID | None
    extraction_job_id: uuid.UUID | None
    asking_stopped: bool
    paused: bool
    live_asks_used: int
    pending_question: AskOut | None
    wrapup_questions: list[AskOut]
    transcript_deleted: bool
    policy: PolicyOut
    started_at: datetime
    ended_at: datetime | None
    created_at: datetime
    updated_at: datetime
    events: list[EventOut] | None = None  # only on GET
