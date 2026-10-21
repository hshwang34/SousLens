"""Gate probes for the Step Oracle: revision/idempotency-style sequencing and boundaries."""

from __future__ import annotations

import pytest

from app.domains.sessions.oracle import (
    Command,
    CommandType,
    ConfirmationRequired,
    InvalidCommand,
    InvalidTransition,
    SessionState,
    SessionStatus,
    StateConflict,
    apply,
)


def st(status: SessionStatus, step: int = 0, revision: int = 0, steps: int = 3) -> SessionState:
    return SessionState(status=status, step_index=step, steps_count=steps, revision=revision)


def go(state: SessionState, command: CommandType, **kw: object) -> SessionState:
    args: dict[str, object] = {"expected_revision": state.revision, "user_confirmed": True}
    args.update(kw)
    return apply(state, Command(command=command, **args)).state  # type: ignore[arg-type]


def test_replaying_an_applied_command_is_a_conflict_carrying_the_new_state() -> None:
    active = st(SessionStatus.ACTIVE, step=0, revision=1)
    command = Command(CommandType.NEXT, expected_revision=1, user_confirmed=True)
    after = apply(active, command).state
    assert after.step_index == 1 and after.revision == 2
    with pytest.raises(StateConflict) as exc:
        apply(after, command)  # same expected_revision replayed: must not double-advance
    assert exc.value.latest == after
    assert exc.value.latest.step_index == 1


def test_stale_conflict_is_checked_before_transition_legality() -> None:
    paused = st(SessionStatus.PAUSED, revision=5)
    with pytest.raises(StateConflict) as exc:
        apply(paused, Command(CommandType.NEXT, expected_revision=4, user_confirmed=True))
    assert exc.value.latest == paused


def test_next_on_last_step_refused_and_state_untouched() -> None:
    last = st(SessionStatus.ACTIVE, step=2, revision=7)
    with pytest.raises(InvalidTransition) as exc:
        go(last, CommandType.NEXT)
    assert exc.value.latest == last


@pytest.mark.parametrize("target", [-1, 3, 99])
def test_jump_out_of_range_rejected(target: int) -> None:
    active = st(SessionStatus.ACTIVE, step=1)
    with pytest.raises(InvalidCommand) as exc:
        go(active, CommandType.JUMP_TO_STEP, step_index=target)
    assert exc.value.latest == active


def test_pause_then_next_is_invalid_transition_then_resume_then_next_works() -> None:
    active = st(SessionStatus.ACTIVE, step=0, revision=1)
    paused = go(active, CommandType.PAUSE)
    assert paused.status is SessionStatus.PAUSED and paused.revision == 2
    with pytest.raises(InvalidTransition):
        go(paused, CommandType.NEXT)
    resumed = go(paused, CommandType.RESUME)
    assert go(resumed, CommandType.NEXT).step_index == 1


@pytest.mark.parametrize("status", [SessionStatus.ACTIVE, SessionStatus.PAUSED])
def test_complete_needs_user_confirmed(status: SessionStatus) -> None:
    state = st(status, step=2)
    with pytest.raises(ConfirmationRequired) as exc:
        go(state, CommandType.COMPLETE, user_confirmed=False)
    assert exc.value.latest == state
    assert go(state, CommandType.COMPLETE).status is SessionStatus.COMPLETED


def test_full_happy_path_revisions_increase_monotonically() -> None:
    s = st(SessionStatus.CREATED)
    seen = [s.revision]
    for command, kw in [
        (CommandType.START, {}),
        (CommandType.NEXT, {}),
        (CommandType.JUMP_TO_STEP, {"step_index": 2}),
        (CommandType.BACK, {}),
        (CommandType.PAUSE, {}),
        (CommandType.RESUME, {}),
        (CommandType.COMPLETE, {}),
    ]:
        s = go(s, command, **kw)
        seen.append(s.revision)
    assert seen == list(range(8))
    assert s.status is SessionStatus.COMPLETED
