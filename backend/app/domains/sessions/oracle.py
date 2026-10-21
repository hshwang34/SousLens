"""Step Oracle — the pure state machine behind cooking sessions (PRD §8.6, §11.1).

Framework-free on purpose: no DB, no HTTP. The Slice 3 endpoint loads the session row, builds a
``SessionState``, calls :func:`apply`, persists the result and records the event. The oracle is
the *only* code allowed to change ``status``/``step_index``/``revision``.

States: ``created → active ↔ paused → completed | abandoned``.

Rules, in evaluation order:

1. ``user_confirmed`` must be true for every command — model output is a proposal only
   (``ConfirmationRequired``).
2. ``expected_revision`` must equal the current revision (``StateConflict``, carries the latest
   state so the caller can return it as the 409 body).
3. The transition must be legal for the current status/step (``InvalidTransition``), and the
   command must be well-formed (``InvalidCommand`` — e.g. ``jump_to_step`` without an index).

Revision rule: every *state-changing* transition bumps ``revision`` by exactly 1. Boundary no-ops
(``back`` at step 0, ``jump_to_step`` to the current step) return the same state with the
revision **unchanged** and ``Result.changed == False``; the caller should not write an event for
them. Idempotency keys are an endpoint concern (duplicate key ⇒ replay stored response), not
the oracle's.

``next`` at the last step is refused: finishing a recipe requires an explicit ``complete``.

Idempotency contract (endpoint, Slice 3)
----------------------------------------
The oracle is deterministic and keeps no memory, so replay protection lives in the endpoint:

1. Every ``POST /sessions/{id}/commands`` carries an ``Idempotency-Key`` header.
2. Before calling :func:`apply`, the endpoint looks up ``session_events`` by
   ``(session_id, idempotency_key)`` (unique index, see ``app/db/models.py``).
3. Hit → return the stored response (``payload_json``) with ``200`` and **do not call the
   oracle** and do not write a second event.
4. Miss → ``apply``; on success persist the new state and insert the event with that key in the
   same transaction. A concurrent duplicate loses on the unique index and must re-read and replay.
5. A replayed key with a *different* command body is a client bug; respond ``STATE_CONFLICT``
   with the latest state rather than applying anything.

``user_confirmed`` is a ``StrictBool``: ``"yes"``, ``1`` or any other truthy value is rejected at
construction, and :func:`apply` additionally checks ``is True`` so duck-typed commands cannot
slip through.
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace
from enum import StrEnum
from typing import Annotated, Any

from pydantic import ConfigDict, Field, StrictBool
from pydantic.dataclasses import dataclass as pydantic_dataclass


class SessionStatus(StrEnum):
    CREATED = "created"
    ACTIVE = "active"
    PAUSED = "paused"
    COMPLETED = "completed"
    ABANDONED = "abandoned"


class CommandType(StrEnum):
    START = "start"
    NEXT = "next"
    BACK = "back"
    JUMP_TO_STEP = "jump_to_step"
    PAUSE = "pause"
    RESUME = "resume"
    COMPLETE = "complete"
    ABANDON = "abandon"


TERMINAL_STATUSES = frozenset({SessionStatus.COMPLETED, SessionStatus.ABANDONED})


@dataclass(frozen=True, slots=True)
class SessionState:
    status: SessionStatus
    step_index: int
    steps_count: int
    revision: int

    def __post_init__(self) -> None:
        if self.steps_count < 0 or self.revision < 0:
            raise ValueError("steps_count and revision must be non-negative")
        if self.step_index < 0 or (self.steps_count and self.step_index >= self.steps_count):
            raise ValueError("step_index out of range for steps_count")

    @property
    def is_terminal(self) -> bool:
        return self.status in TERMINAL_STATUSES

    @property
    def last_step_index(self) -> int:
        return max(self.steps_count - 1, 0)


@pydantic_dataclass(frozen=True, config=ConfigDict(extra="forbid"))
class Command:
    command: CommandType
    expected_revision: Annotated[int, Field(ge=0)]
    user_confirmed: StrictBool
    client_source: str = "ios_button"
    metadata: dict[str, Any] = field(default_factory=dict)
    step_index: int | None = None


@dataclass(frozen=True, slots=True)
class Result:
    state: SessionState
    changed: bool
    event_type: str | None


class OracleError(Exception):
    """Base class for every refusal. ``latest`` is always the unchanged current state."""

    def __init__(self, message: str, latest: SessionState) -> None:
        super().__init__(message)
        self.message = message
        self.latest = latest


class ConfirmationRequired(OracleError):
    """``user_confirmed`` was false: an unconfirmed (possibly model-proposed) command."""


class StateConflict(OracleError):
    """``expected_revision`` is stale; respond 409 with ``latest``."""


class InvalidTransition(OracleError):
    """Command is not allowed from the current status / position."""


class InvalidCommand(OracleError):
    """Structurally invalid command (missing or out-of-range ``step_index``)."""


def apply(state: SessionState, command: Command) -> Result:
    """Validate ``command`` against ``state`` and return the resulting state."""
    if command.user_confirmed is not True:
        raise ConfirmationRequired(
            f"'{command.command}' requires user confirmation before it is committed", state
        )
    if command.expected_revision != state.revision:
        raise StateConflict(
            f"expected_revision {command.expected_revision} does not match current revision "
            f"{state.revision}",
            state,
        )
    if state.is_terminal:
        raise InvalidTransition(f"session is {state.status}; no further commands allowed", state)

    handler = _HANDLERS[command.command]
    return handler(state, command)


def _bump(state: SessionState, event_type: str, **changes: Any) -> Result:
    new_state = replace(state, revision=state.revision + 1, **changes)
    return Result(state=new_state, changed=True, event_type=event_type)


def _noop(state: SessionState) -> Result:
    return Result(state=state, changed=False, event_type=None)


def _require_status(state: SessionState, command: Command, *allowed: SessionStatus) -> None:
    if state.status not in allowed:
        wanted = " or ".join(s.value for s in allowed)
        raise InvalidTransition(
            f"'{command.command}' requires status {wanted}, session is {state.status}", state
        )


def _start(state: SessionState, command: Command) -> Result:
    _require_status(state, command, SessionStatus.CREATED)
    if state.steps_count < 1:
        raise InvalidTransition("cannot start a session with no steps", state)
    return _bump(state, "session_started", status=SessionStatus.ACTIVE, step_index=0)


def _next(state: SessionState, command: Command) -> Result:
    _require_status(state, command, SessionStatus.ACTIVE)
    if state.step_index >= state.last_step_index:
        raise InvalidTransition(
            "already on the last step; send 'complete' to finish the recipe", state
        )
    return _bump(state, "step_advanced", step_index=state.step_index + 1)


def _back(state: SessionState, command: Command) -> Result:
    _require_status(state, command, SessionStatus.ACTIVE)
    if state.step_index == 0:
        return _noop(state)
    return _bump(state, "step_reverted", step_index=state.step_index - 1)


def _jump(state: SessionState, command: Command) -> Result:
    _require_status(state, command, SessionStatus.ACTIVE)
    target = command.step_index
    if target is None:
        raise InvalidCommand("'jump_to_step' requires step_index", state)
    if target < 0 or target > state.last_step_index:
        raise InvalidCommand(f"step_index {target} out of range 0..{state.last_step_index}", state)
    if target == state.step_index:
        return _noop(state)
    return _bump(state, "step_jumped", step_index=target)


def _pause(state: SessionState, command: Command) -> Result:
    _require_status(state, command, SessionStatus.ACTIVE)
    return _bump(state, "session_paused", status=SessionStatus.PAUSED)


def _resume(state: SessionState, command: Command) -> Result:
    _require_status(state, command, SessionStatus.PAUSED)
    return _bump(state, "session_resumed", status=SessionStatus.ACTIVE)


def _complete(state: SessionState, command: Command) -> Result:
    _require_status(state, command, SessionStatus.ACTIVE, SessionStatus.PAUSED)
    return _bump(state, "session_completed", status=SessionStatus.COMPLETED)


def _abandon(state: SessionState, command: Command) -> Result:
    _require_status(
        state, command, SessionStatus.CREATED, SessionStatus.ACTIVE, SessionStatus.PAUSED
    )
    return _bump(state, "session_abandoned", status=SessionStatus.ABANDONED)


_HANDLERS = {
    CommandType.START: _start,
    CommandType.NEXT: _next,
    CommandType.BACK: _back,
    CommandType.JUMP_TO_STEP: _jump,
    CommandType.PAUSE: _pause,
    CommandType.RESUME: _resume,
    CommandType.COMPLETE: _complete,
    CommandType.ABANDON: _abandon,
}
