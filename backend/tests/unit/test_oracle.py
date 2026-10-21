"""Step Oracle transition matrix (PRD §8.6, §11.1)."""

from __future__ import annotations

from types import SimpleNamespace

import pytest
from pydantic import ValidationError

from app.domains.sessions.oracle import (
    Command,
    CommandType,
    ConfirmationRequired,
    InvalidCommand,
    InvalidTransition,
    OracleError,
    Result,
    SessionState,
    SessionStatus,
    StateConflict,
    apply,
)


def state(status: SessionStatus, step: int = 0, steps: int = 5, revision: int = 3) -> SessionState:
    return SessionState(status=status, step_index=step, steps_count=steps, revision=revision)


def cmd(command: CommandType, st: SessionState, **kwargs: object) -> Command:
    base = {"expected_revision": st.revision, "user_confirmed": True}
    base.update(kwargs)
    return Command(command=command, **base)  # type: ignore[arg-type]


CREATED = state(SessionStatus.CREATED)
ACTIVE = state(SessionStatus.ACTIVE, step=2)
PAUSED = state(SessionStatus.PAUSED, step=2)
COMPLETED = state(SessionStatus.COMPLETED, step=4)
ABANDONED = state(SessionStatus.ABANDONED, step=1)


def assert_bumped(result: Result, before: SessionState, event: str) -> None:
    assert result.changed is True
    assert result.event_type == event
    assert result.state.revision == before.revision + 1


# --- guard order --------------------------------------------------------------------------


@pytest.mark.parametrize("command", list(CommandType))
def test_unconfirmed_command_is_rejected_before_anything_else(command: CommandType) -> None:
    with pytest.raises(ConfirmationRequired) as exc:
        apply(ACTIVE, cmd(command, ACTIVE, user_confirmed=False, expected_revision=99))
    assert exc.value.latest == ACTIVE


@pytest.mark.parametrize("command", list(CommandType))
def test_stale_revision_is_a_conflict_carrying_latest_state(command: CommandType) -> None:
    with pytest.raises(StateConflict) as exc:
        apply(ACTIVE, cmd(command, ACTIVE, expected_revision=ACTIVE.revision - 1))
    assert exc.value.latest == ACTIVE


def test_future_revision_is_also_a_conflict() -> None:
    with pytest.raises(StateConflict):
        apply(ACTIVE, cmd(CommandType.NEXT, ACTIVE, expected_revision=ACTIVE.revision + 1))


@pytest.mark.parametrize("terminal", [COMPLETED, ABANDONED])
@pytest.mark.parametrize("command", list(CommandType))
def test_terminal_sessions_accept_nothing(terminal: SessionState, command: CommandType) -> None:
    with pytest.raises(InvalidTransition):
        apply(terminal, cmd(command, terminal, step_index=0))


# --- start --------------------------------------------------------------------------------


def test_start_moves_created_to_active_step_zero() -> None:
    result = apply(CREATED, cmd(CommandType.START, CREATED))
    assert_bumped(result, CREATED, "session_started")
    assert result.state.status is SessionStatus.ACTIVE
    assert result.state.step_index == 0


@pytest.mark.parametrize("st", [ACTIVE, PAUSED])
def test_start_only_from_created(st: SessionState) -> None:
    with pytest.raises(InvalidTransition):
        apply(st, cmd(CommandType.START, st))


def test_start_with_no_steps_is_invalid() -> None:
    empty = SessionState(status=SessionStatus.CREATED, step_index=0, steps_count=0, revision=0)
    with pytest.raises(InvalidTransition):
        apply(empty, cmd(CommandType.START, empty))


# --- next ---------------------------------------------------------------------------------


def test_next_advances_one_step_and_bumps_revision() -> None:
    result = apply(ACTIVE, cmd(CommandType.NEXT, ACTIVE))
    assert_bumped(result, ACTIVE, "step_advanced")
    assert result.state.step_index == ACTIVE.step_index + 1
    assert result.state.status is SessionStatus.ACTIVE


def test_next_on_last_step_requires_complete() -> None:
    last = state(SessionStatus.ACTIVE, step=4)
    with pytest.raises(InvalidTransition, match="complete"):
        apply(last, cmd(CommandType.NEXT, last))


@pytest.mark.parametrize("st", [CREATED, PAUSED])
def test_next_only_while_active(st: SessionState) -> None:
    with pytest.raises(InvalidTransition):
        apply(st, cmd(CommandType.NEXT, st))


def test_revision_chain_across_sequence() -> None:
    st = CREATED
    expected_revision = CREATED.revision
    for command in (CommandType.START, CommandType.NEXT, CommandType.NEXT, CommandType.PAUSE):
        st = apply(st, cmd(command, st)).state
        expected_revision += 1
        assert st.revision == expected_revision
    assert st.status is SessionStatus.PAUSED
    assert st.step_index == 2


# --- back ---------------------------------------------------------------------------------


def test_back_decrements_step() -> None:
    result = apply(ACTIVE, cmd(CommandType.BACK, ACTIVE))
    assert_bumped(result, ACTIVE, "step_reverted")
    assert result.state.step_index == ACTIVE.step_index - 1


def test_back_at_step_zero_is_a_noop_without_revision_bump() -> None:
    first = state(SessionStatus.ACTIVE, step=0)
    result = apply(first, cmd(CommandType.BACK, first))
    assert result.changed is False
    assert result.event_type is None
    assert result.state == first


@pytest.mark.parametrize("st", [CREATED, PAUSED])
def test_back_only_while_active(st: SessionState) -> None:
    with pytest.raises(InvalidTransition):
        apply(st, cmd(CommandType.BACK, st))


# --- jump_to_step -------------------------------------------------------------------------


@pytest.mark.parametrize("target", [0, 1, 3, 4])
def test_jump_to_valid_step(target: int) -> None:
    result = apply(ACTIVE, cmd(CommandType.JUMP_TO_STEP, ACTIVE, step_index=target))
    assert_bumped(result, ACTIVE, "step_jumped")
    assert result.state.step_index == target


def test_jump_to_current_step_is_a_noop() -> None:
    result = apply(ACTIVE, cmd(CommandType.JUMP_TO_STEP, ACTIVE, step_index=ACTIVE.step_index))
    assert result.changed is False
    assert result.state == ACTIVE


@pytest.mark.parametrize("target", [-1, 5, 100])
def test_jump_out_of_range_is_invalid_command(target: int) -> None:
    with pytest.raises(InvalidCommand):
        apply(ACTIVE, cmd(CommandType.JUMP_TO_STEP, ACTIVE, step_index=target))


def test_jump_without_step_index_is_invalid_command() -> None:
    with pytest.raises(InvalidCommand):
        apply(ACTIVE, cmd(CommandType.JUMP_TO_STEP, ACTIVE))


def test_jump_only_while_active() -> None:
    with pytest.raises(InvalidTransition):
        apply(PAUSED, cmd(CommandType.JUMP_TO_STEP, PAUSED, step_index=0))


# --- pause / resume -----------------------------------------------------------------------


def test_pause_preserves_step() -> None:
    result = apply(ACTIVE, cmd(CommandType.PAUSE, ACTIVE))
    assert_bumped(result, ACTIVE, "session_paused")
    assert result.state.status is SessionStatus.PAUSED
    assert result.state.step_index == ACTIVE.step_index


def test_resume_preserves_step() -> None:
    result = apply(PAUSED, cmd(CommandType.RESUME, PAUSED))
    assert_bumped(result, PAUSED, "session_resumed")
    assert result.state.status is SessionStatus.ACTIVE
    assert result.state.step_index == PAUSED.step_index


@pytest.mark.parametrize("st", [CREATED, PAUSED])
def test_pause_only_while_active(st: SessionState) -> None:
    with pytest.raises(InvalidTransition):
        apply(st, cmd(CommandType.PAUSE, st))


@pytest.mark.parametrize("st", [CREATED, ACTIVE])
def test_resume_only_while_paused(st: SessionState) -> None:
    with pytest.raises(InvalidTransition):
        apply(st, cmd(CommandType.RESUME, st))


# --- complete / abandon -------------------------------------------------------------------


@pytest.mark.parametrize("st", [ACTIVE, PAUSED, state(SessionStatus.ACTIVE, step=4)])
def test_complete_from_active_or_paused(st: SessionState) -> None:
    result = apply(st, cmd(CommandType.COMPLETE, st))
    assert_bumped(result, st, "session_completed")
    assert result.state.status is SessionStatus.COMPLETED
    assert result.state.step_index == st.step_index


def test_complete_not_from_created() -> None:
    with pytest.raises(InvalidTransition):
        apply(CREATED, cmd(CommandType.COMPLETE, CREATED))


@pytest.mark.parametrize("st", [CREATED, ACTIVE, PAUSED])
def test_abandon_from_any_non_terminal_state(st: SessionState) -> None:
    result = apply(st, cmd(CommandType.ABANDON, st))
    assert_bumped(result, st, "session_abandoned")
    assert result.state.status is SessionStatus.ABANDONED


# --- invariants ---------------------------------------------------------------------------


def test_state_rejects_out_of_range_step_index() -> None:
    with pytest.raises(ValueError, match="step_index"):
        SessionState(status=SessionStatus.ACTIVE, step_index=5, steps_count=5, revision=0)


def test_apply_never_mutates_input_state() -> None:
    before = state(SessionStatus.ACTIVE, step=1)
    apply(before, cmd(CommandType.NEXT, before))
    assert before == state(SessionStatus.ACTIVE, step=1)


def test_errors_expose_message_and_latest() -> None:
    with pytest.raises(OracleError) as exc:
        apply(PAUSED, cmd(CommandType.NEXT, PAUSED))
    assert "paused" in exc.value.message
    assert exc.value.latest is PAUSED


def test_command_metadata_and_client_source_do_not_affect_transition() -> None:
    command = Command(
        command=CommandType.NEXT,
        expected_revision=ACTIVE.revision,
        user_confirmed=True,
        client_source="voice_intent",
        metadata={"proposed_by": "coach"},
    )
    assert apply(ACTIVE, command).state.step_index == ACTIVE.step_index + 1


# --- strict confirmation ------------------------------------------------------------------


@pytest.mark.parametrize("truthy", ["yes", "true", 1, 2, [True], {"ok": True}])
def test_command_rejects_non_bool_user_confirmed_at_construction(truthy: object) -> None:
    with pytest.raises(ValidationError):
        Command(command=CommandType.NEXT, expected_revision=0, user_confirmed=truthy)  # type: ignore[arg-type]


@pytest.mark.parametrize("truthy", ["yes", 1, [True]])
def test_apply_rejects_duck_typed_truthy_confirmation(truthy: object) -> None:
    fake = SimpleNamespace(
        command=CommandType.NEXT,
        expected_revision=ACTIVE.revision,
        user_confirmed=truthy,
        client_source="ios_button",
        metadata={},
        step_index=None,
    )
    with pytest.raises(ConfirmationRequired):
        apply(ACTIVE, fake)  # type: ignore[arg-type]


def test_command_rejects_negative_expected_revision_and_unknown_fields() -> None:
    with pytest.raises(ValidationError):
        Command(command=CommandType.NEXT, expected_revision=-1, user_confirmed=True)
    with pytest.raises(ValidationError):
        Command(command=CommandType.NEXT, expected_revision=0, user_confirmed=True, nope=1)  # type: ignore[call-arg]


def test_command_is_frozen() -> None:
    command = Command(command=CommandType.NEXT, expected_revision=0, user_confirmed=True)
    with pytest.raises((AttributeError, TypeError, ValidationError)):
        command.user_confirmed = False  # type: ignore[misc]
