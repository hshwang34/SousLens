"""Cooking sessions (COOK-01/02/06/07/08, PRD §8.6, §10.3, §11.1, brief 005 contract).

* ``create`` pins the version (immutable forever), the approved adaptations (validated against
  the version and the caller's allergies), step 0 and the relevant pantry subset.
* ``run_command`` implements the idempotency contract in ``oracle.py`` exactly. The session row
  is locked ``FOR UPDATE`` first, so two concurrent commands serialise: with the same
  ``expected_revision`` and different keys exactly one wins and the other gets 409; with the
  same key the second replays the first's stored response.
* Every state change goes through :func:`app.domains.sessions.oracle.apply`; this module only
  persists what the oracle returned plus the command's side effect (adaptation, timer, outcome).
"""

from __future__ import annotations

import hashlib
import json
import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import func, inspect, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from app.core.errors import (
    ConfirmationRequired,
    InvalidTransition,
    NotFound,
    StateConflict,
    ValidationError,
)
from app.db.models import (
    CookingSession,
    PantryItem,
    Recipe,
    RecipeVariation,
    RecipeVersion,
    SessionAdaptation,
    SessionEvent,
    SessionNote,
    SessionStatus,
    SubstitutionSuggestionRecord,
    Timer,
    TimerStatus,
    User,
)
from app.domains import usage
from app.domains.matching.dictionary import IngredientDictionary, load_dictionary
from app.domains.matching.normalize import conjuncts
from app.domains.pantry.service import lock_user
from app.domains.recipes import service as recipes_service
from app.domains.recipes.versions import version_meta
from app.domains.safety.content import StructuralContext, conflicts, structural_verdict
from app.domains.sessions import oracle
from app.domains.sessions.schemas import (
    AdaptationIn,
    AdaptationOut,
    CommandIn,
    NoteIn,
    NoteOut,
    OutcomeOut,
    PantrySnapshotItem,
    SessionCreateIn,
    SessionOut,
    SessionStepOut,
    SessionSummary,
    SuggestedTimer,
    TimerOut,
)
from app.domains.substitutions.adapt import AdaptationSpec, compose_overlay, suggested_timer
from app.domains.substitutions.service import (
    VersionContext,
    context_from,
    target_names,
    version_context,
)
from app.domains.users import preferences

LABELS = {"rule": "Common swap", "ai": "AI suggested adaptation"}
ACTIVE_STATUSES = (SessionStatus.CREATED, SessionStatus.ACTIVE, SessionStatus.PAUSED)
MAX_RUNNING_TIMERS = 10
MAX_NOTES = 50
MAX_OPEN_SESSIONS = 3  # created/active/paused per user
SESSIONS_PER_HOUR = 30  # per user, counted in usage_events (survives deletion)
LIST_LIMIT = 50


def _now() -> datetime:
    return datetime.now(UTC)


# --------------------------------------------------------------------------- loading


async def _owned(
    session: AsyncSession, user: User, session_id: uuid.UUID, *, lock: bool = False
) -> CookingSession:
    stmt = select(CookingSession).where(
        CookingSession.id == session_id, CookingSession.owner_user_id == user.id
    )
    if lock:
        stmt = stmt.with_for_update().execution_options(populate_existing=True)
    row = (await session.execute(stmt)).scalar_one_or_none()
    if row is None:
        raise NotFound("Session not found")
    return row


async def _pinned(session: AsyncSession, row: CookingSession) -> tuple[RecipeVersion, Recipe]:
    """The pinned version and its recipe. The session owner can always read it."""
    stmt = (
        select(RecipeVersion, Recipe)
        .join(Recipe, Recipe.id == RecipeVersion.recipe_id)
        .options(joinedload(Recipe.owner))
        .where(RecipeVersion.id == row.recipe_version_id)
    )
    version, recipe = (await session.execute(stmt)).unique().one()
    return version, recipe


async def active_adaptations(
    session: AsyncSession, session_id: uuid.UUID
) -> list[SessionAdaptation]:
    stmt = (
        select(SessionAdaptation)
        .where(SessionAdaptation.session_id == session_id, SessionAdaptation.reverted_at.is_(None))
        .order_by(SessionAdaptation.approved_at, SessionAdaptation.id)
    )
    return list((await session.execute(stmt)).scalars())


async def session_timers(session: AsyncSession, session_id: uuid.UUID) -> list[Timer]:
    stmt = select(Timer).where(Timer.session_id == session_id).order_by(Timer.created_at, Timer.id)
    return list((await session.execute(stmt)).scalars())


def timer_status(timer: Timer, now: datetime) -> str:
    if timer.status == TimerStatus.CANCELLED:
        return "cancelled"
    if timer.status == TimerStatus.FIRED or timer.target_at <= now:
        return "done"  # absolute deadline: done on read once target_at has passed (COOK-06)
    return "running"


# --------------------------------------------------------------------------- views


async def build_view(
    session: AsyncSession, row: CookingSession, settings_share_base: str, now: datetime
) -> SessionOut:
    if "updated_at" in inspect(row).unloaded:  # server onupdate expired it on flush
        await session.refresh(row, ["updated_at"])
    version, recipe = await _pinned(session, row)
    ctx = context_from(version, recipe)
    adaptations = await active_adaptations(session, row.id)
    timers = await session_timers(session, row.id)
    notes = (
        (
            await session.execute(
                select(SessionNote)
                .where(SessionNote.session_id == row.id)
                .order_by(SessionNote.created_at, SessionNote.id)
            )
        )
        .scalars()
        .all()
    )
    overlay: dict[str, Any] = (row.adaptation_json or {}).get("steps", {})
    steps: list[SessionStepOut] = []
    for step in ctx.steps:
        entry = overlay.get(step.id)
        timer = suggested_timer(step.instruction, step.order)
        steps.append(
            SessionStepOut(
                step_id=step.id,
                order=step.order,
                instruction=entry["instruction"] if entry else step.instruction,
                original_instruction=step.instruction,
                adapted=entry is not None,
                adaptation_ids=[uuid.UUID(i) for i in entry["adaptation_ids"]] if entry else [],
                suggested_timer=SuggestedTimer.model_validate(timer) if timer else None,
            )
        )
    outcome = row.outcome_json
    return SessionOut(
        id=row.id,
        recipe_version_id=row.recipe_version_id,
        recipe_id=recipe.id,
        status=row.status.value,
        step_index=row.step_index,
        steps_count=len(ctx.steps),
        revision=row.revision,
        recipe=recipes_service.to_detail(
            recipe, version, saved=None, share_url_base=settings_share_base
        ),
        adaptations=[_adaptation_out(a) for a in adaptations],
        steps=steps,
        timers=[
            TimerOut(
                id=t.id,
                step_index=t.step_index,
                label=t.label,
                target_at=t.target_at,
                status=timer_status(t, now),  # type: ignore[arg-type]
            )
            for t in timers
        ],
        notes=[NoteOut(id=n.id, text=n.text, created_at=n.created_at) for n in notes],
        outcome=OutcomeOut.model_validate(outcome) if outcome else None,
        pantry_snapshot=[PantrySnapshotItem.model_validate(p) for p in row.pantry_snapshot_json],
        started_at=row.started_at,
        ended_at=row.ended_at,
        updated_at=row.updated_at,
    )


def _adaptation_out(a: SessionAdaptation) -> AdaptationOut:
    return AdaptationOut(
        id=a.id,
        ingredient_ref=a.ingredient_ref,
        original=a.original,
        replacement=a.replacement,
        ratio_or_amount=a.ratio_or_amount,
        source=a.source,  # type: ignore[arg-type]
        label=LABELS[a.source],  # type: ignore[arg-type]
        reason=a.reason,
        approved_at=a.approved_at,
    )


def _dump(view: SessionOut) -> dict[str, Any]:
    return view.model_dump(mode="json")


# --------------------------------------------------------------------------- adaptations


async def resolve_adaptation(
    session: AsyncSession,
    user: User,
    ctx: VersionContext,
    body: AdaptationIn,
    prof: preferences.Profile,
    dictionary: IngredientDictionary,
    now: datetime,
    *,
    field: str,
) -> dict[str, Any]:
    """Validate one adaptation against the pinned version and the caller's allergies *now*."""
    ingredient = ctx.ingredient(body.ingredient_ref)
    if ingredient is None:
        raise ValidationError(
            "ingredient_ref is not an ingredient of this recipe version",
            extra={"fields": [f"{field}.ingredient_ref"]},
        )
    if body.suggestion_id is not None:
        record = await session.get(SubstitutionSuggestionRecord, body.suggestion_id)
        if (
            record is None
            or record.owner_user_id != user.id
            or record.recipe_version_id != ctx.version_id
            or record.ingredient_ref != ingredient.id
            or record.expires_at <= now
        ):
            raise ValidationError(
                "That suggestion is unknown or expired; ask for suggestions again",
                extra={"fields": [f"{field}.suggestion_id"]},
            )
        payload = record.payload_json
        spec = {
            "replacement": payload["candidate"],
            "ratio_or_amount": payload.get("ratio_or_amount"),
            "source": payload["source"],
            "reason": body.reason or f"{ingredient.name} unavailable",
            "suggestion_id": record.id,
        }
    else:
        spec = {
            "replacement": body.replacement,
            "ratio_or_amount": body.ratio_or_amount,
            "source": body.source,
            "reason": body.reason or f"{ingredient.name} unavailable",
            "suggestion_id": None,
        }
    hits = conflicts(
        f"{spec['replacement']} {spec['ratio_or_amount'] or ''}", prof.allergies, dictionary
    )
    if hits:
        raise ValidationError(
            f"This swap contains something on your allergy list ({', '.join(hits)})",
            extra={"fields": [f"{field}.replacement"], "details": {"allergies": hits}},
        )
    steps = [s for s in ctx.steps if ingredient.id in s.ingredient_refs]
    blocked = structural_verdict(
        StructuralContext(
            target_names=frozenset(target_names(ingredient.name, dictionary)),
            step_texts=tuple(s.instruction for s in steps),
            recipe_texts=(ctx.title,),
        )
    )
    if blocked is not None:
        raise ValidationError(blocked.reason, extra={"fields": [f"{field}.ingredient_ref"]})
    return {"ingredient_ref": ingredient.id, "original": ingredient.name, **spec}


def recompute_overlay(
    row: CookingSession,
    ctx: VersionContext,
    adaptations: list[SessionAdaptation],
    dictionary: IngredientDictionary,
) -> None:
    specs = [
        AdaptationSpec(
            id=str(a.id),
            ingredient_ref=a.ingredient_ref,
            original=a.original,
            replacement=a.replacement,
            ratio_or_amount=a.ratio_or_amount,
        )
        for a in adaptations
    ]
    row.adaptation_json = {"steps": compose_overlay(ctx.steps, ctx.ingredients, specs, dictionary)}


# --------------------------------------------------------------------------- create / read


def _relevant_keys(ctx: VersionContext, dictionary: IngredientDictionary) -> set[str]:
    keys: set[str] = set()
    for ingredient in ctx.ingredients:
        for part in conjuncts(ingredient.name, dictionary):
            keys.update(target_names(part, dictionary))
    return keys


async def create(
    session: AsyncSession, user: User, body: SessionCreateIn, share_base: str
) -> SessionOut:
    now = _now()
    ctx = await version_context(session, user, body.recipe_version_id)
    await lock_user(session, user.id, "sessions")
    open_ids = list(
        (
            await session.execute(
                select(CookingSession.id)
                .where(
                    CookingSession.owner_user_id == user.id,
                    CookingSession.status.in_(ACTIVE_STATUSES),
                )
                .order_by(CookingSession.updated_at.desc(), CookingSession.id.desc())
            )
        ).scalars()
    )
    if len(open_ids) >= MAX_OPEN_SESSIONS:
        raise StateConflict(
            f"You already have {len(open_ids)} sessions in progress; resume or abandon one first",
            extra={"details": {"open_session_ids": [str(i) for i in open_ids]}},
        )
    await usage.reserve(
        session,
        user.id,
        usage.SESSION_CREATED,
        limit=SESSIONS_PER_HOUR,
        window=timedelta(hours=1),
        now=now,
        message="Too many new cooking sessions in the last hour; try again later",
    )
    dictionary = await load_dictionary(session)
    prof = await preferences.profile(session, user)
    specs = [
        await resolve_adaptation(
            session, user, ctx, a, prof, dictionary, now, field=f"adaptations.{i}"
        )
        for i, a in enumerate(body.adaptations)
    ]
    refs = [s["ingredient_ref"] for s in specs]
    if len(set(refs)) != len(refs):
        raise ValidationError(
            "at most one adaptation per ingredient", extra={"fields": ["adaptations"]}
        )
    keys = _relevant_keys(ctx, dictionary)
    pantry = (
        await session.execute(
            select(PantryItem)
            .where(PantryItem.owner_user_id == user.id, PantryItem.normalized_name.in_(keys))
            .order_by(PantryItem.normalized_name, PantryItem.id)
        )
    ).scalars()
    row = CookingSession(
        owner_user_id=user.id,
        recipe_version_id=ctx.version_id,
        status=SessionStatus.CREATED,
        step_index=0,
        revision=0,
        pantry_snapshot_json=[
            {"pantry_item_id": str(p.id), "normalized_name": p.normalized_name} for p in pantry
        ],
        adaptation_json={"steps": {}},
        created_at=now,
        updated_at=now,
    )
    session.add(row)
    await session.flush()
    rows = [
        SessionAdaptation(session_id=row.id, approved_at=now, created_at=now, **spec)
        for spec in specs
    ]
    session.add_all(rows)
    await session.flush()
    recompute_overlay(row, ctx, rows, dictionary)
    session.add(
        SessionEvent(
            session_id=row.id,
            sequence=0,
            type="session_created",
            payload_json={
                "recipe_version_id": str(ctx.version_id),
                "adaptations": [str(a.id) for a in rows],
            },
            created_at=now,
        )
    )
    await session.flush()
    return await build_view(session, row, share_base, now)


async def get(
    session: AsyncSession, user: User, session_id: uuid.UUID, share_base: str
) -> SessionOut:
    row = await _owned(session, user, session_id)
    return await build_view(session, row, share_base, _now())


async def list_sessions(
    session: AsyncSession, user: User, *, active_only: bool
) -> list[SessionSummary]:
    stmt = (
        select(CookingSession, RecipeVersion, Recipe)
        .join(RecipeVersion, RecipeVersion.id == CookingSession.recipe_version_id)
        .join(Recipe, Recipe.id == RecipeVersion.recipe_id)
        .where(CookingSession.owner_user_id == user.id)
        .order_by(CookingSession.updated_at.desc(), CookingSession.id.desc())
        .limit(LIST_LIMIT)
    )
    if active_only:
        stmt = stmt.where(CookingSession.status.in_(ACTIVE_STATUSES))
    items: list[SessionSummary] = []
    for row, version, recipe in (await session.execute(stmt)).all():
        items.append(
            SessionSummary(
                id=row.id,
                recipe_version_id=version.id,
                recipe_id=recipe.id,
                title=version_meta(recipe, version)["title"],
                status=row.status.value,
                step_index=row.step_index,
                steps_count=len(version.step_json or []),
                updated_at=row.updated_at,
            )
        )
    return items


async def delete(session: AsyncSession, user: User, session_id: uuid.UUID) -> None:
    row = await _owned(session, user, session_id, lock=True)
    await session.delete(row)  # events, messages, timers, notes, adaptations cascade in the DB
    await session.flush()


async def add_note(
    session: AsyncSession, user: User, session_id: uuid.UUID, body: NoteIn
) -> NoteOut:
    row = await _owned(session, user, session_id, lock=True)
    count = await session.scalar(
        select(func.count()).select_from(SessionNote).where(SessionNote.session_id == row.id)
    )
    if (count or 0) >= MAX_NOTES:
        raise ValidationError(f"at most {MAX_NOTES} notes per session", extra={"fields": ["text"]})
    now = _now()
    note = SessionNote(session_id=row.id, text=body.text, created_at=now)
    session.add(note)
    row.updated_at = now
    await session.flush()
    return NoteOut(id=note.id, text=note.text, created_at=now)


# --------------------------------------------------------------------------- commands


def request_hash(body: CommandIn) -> str:
    canonical = json.dumps(
        body.model_dump(mode="json", exclude_none=True), sort_keys=True, separators=(",", ":")
    )
    return hashlib.sha256(canonical.encode()).hexdigest()


def _state(row: CookingSession, steps_count: int) -> oracle.SessionState:
    return oracle.SessionState(
        status=oracle.SessionStatus(row.status.value),
        step_index=row.step_index,
        steps_count=steps_count,
        revision=row.revision,
    )


async def run_command(
    session: AsyncSession,
    user: User,
    session_id: uuid.UUID,
    idempotency_key: str,
    body: CommandIn,
    share_base: str,
) -> dict[str, Any]:
    now = _now()
    row = await _owned(session, user, session_id, lock=True)
    digest = request_hash(body)

    async def latest() -> dict[str, Any]:
        return _dump(await build_view(session, row, share_base, now))

    prior = (
        await session.execute(
            select(SessionEvent).where(
                SessionEvent.session_id == row.id, SessionEvent.idempotency_key == idempotency_key
            )
        )
    ).scalar_one_or_none()
    if prior is not None:
        if prior.request_hash == digest and prior.response_json is not None:
            # Replay: no oracle call, no second event. JSONB does not keep key order, so the
            # stored body goes back through the response model to come out byte-identical.
            return _dump(SessionOut.model_validate(prior.response_json))
        raise StateConflict(
            "This Idempotency-Key was already used for a different command",
            extra={"details": {"session": await latest()}},
        )

    if body.user_confirmed is not True:
        raise ConfirmationRequired(f"'{body.command}' requires user confirmation")

    version, recipe = await _pinned(session, row)
    ctx = context_from(version, recipe)
    command = oracle.Command(
        command=body.command,
        expected_revision=body.expected_revision,
        user_confirmed=True,
        client_source=body.client_source,
        step_index=body.step_index,
    )
    try:
        result = oracle.apply(_state(row, len(ctx.steps)), command)
    except oracle.StateConflict as exc:
        raise StateConflict(exc.message, extra={"details": {"session": await latest()}}) from exc
    except oracle.InvalidTransition as exc:
        raise InvalidTransition(
            exc.message, extra={"details": {"session": await latest()}}
        ) from exc
    except oracle.InvalidCommand as exc:
        raise ValidationError(exc.message, extra={"fields": ["step_index"]}) from exc
    except oracle.ConfirmationRequired as exc:  # pragma: no cover - checked above
        raise ConfirmationRequired(exc.message) from exc

    if not result.changed:
        return await latest()  # boundary no-op: revision unchanged, no event

    await _side_effect(session, user, row, ctx, body, now)
    row.status = SessionStatus(result.state.status.value)
    row.step_index = result.state.step_index
    row.revision = result.state.revision
    row.updated_at = now
    await session.flush()
    response = await latest()
    session.add(
        SessionEvent(
            session_id=row.id,
            sequence=row.revision,
            type=result.event_type or str(body.command),
            payload_json=body.model_dump(mode="json", exclude_none=True),
            idempotency_key=idempotency_key,
            request_hash=digest,
            response_json=response,
            created_at=now,
        )
    )
    await session.flush()
    return response


async def _side_effect(
    session: AsyncSession,
    user: User,
    row: CookingSession,
    ctx: VersionContext,
    body: CommandIn,
    now: datetime,
) -> None:
    command = body.command
    T = oracle.CommandType
    if command == T.START:
        row.started_at = now
    elif command in (T.COMPLETE, T.ABANDON):
        row.ended_at = now
        if command == T.COMPLETE and body.outcome is not None:
            saved = False
            if body.outcome.save_changes:
                saved = await save_variation(session, user, row, ctx, now)
            row.outcome_json = {"result": body.outcome.result, "saved_changes": saved}
    elif command == T.APPROVE_ADAPTATION:
        if body.adaptation is None:
            raise ValidationError(
                "approve_adaptation needs adaptation", extra={"fields": ["adaptation"]}
            )
        dictionary = await load_dictionary(session)
        prof = await preferences.profile(session, user)
        spec = await resolve_adaptation(
            session, user, ctx, body.adaptation, prof, dictionary, now, field="adaptation"
        )
        current = await active_adaptations(session, row.id)
        for existing in current:
            if existing.ingredient_ref == spec["ingredient_ref"]:
                existing.reverted_at = now  # a new swap for the same ingredient replaces it
        await session.flush()
        session.add(SessionAdaptation(session_id=row.id, approved_at=now, created_at=now, **spec))
        await session.flush()
        recompute_overlay(row, ctx, await active_adaptations(session, row.id), dictionary)
    elif command == T.REVERT_ADAPTATION:
        if body.adaptation_id is None:
            raise ValidationError(
                "revert_adaptation needs adaptation_id", extra={"fields": ["adaptation_id"]}
            )
        target = await session.get(SessionAdaptation, body.adaptation_id)
        if target is None or target.session_id != row.id:
            raise NotFound("Adaptation not found")
        if target.reverted_at is not None:
            raise InvalidTransition("That adaptation was already reverted")
        target.reverted_at = now
        await session.flush()
        dictionary = await load_dictionary(session)
        recompute_overlay(row, ctx, await active_adaptations(session, row.id), dictionary)
    elif command == T.START_TIMER:
        if body.timer is None:
            raise ValidationError("start_timer needs timer", extra={"fields": ["timer"]})
        running = [
            t for t in await session_timers(session, row.id) if timer_status(t, now) == "running"
        ]
        if len(running) >= MAX_RUNNING_TIMERS:
            raise ValidationError(
                f"at most {MAX_RUNNING_TIMERS} running timers", extra={"fields": ["timer"]}
            )
        session.add(
            Timer(
                session_id=row.id,
                step_index=row.step_index,
                label=body.timer.label,
                target_at=now + timedelta(seconds=body.timer.duration_seconds),
                status=TimerStatus.RUNNING,
                created_at=now,
            )
        )
    elif command == T.CANCEL_TIMER:
        if body.timer_id is None:
            raise ValidationError("cancel_timer needs timer_id", extra={"fields": ["timer_id"]})
        timer = await session.get(Timer, body.timer_id)
        if timer is None or timer.session_id != row.id:
            raise NotFound("Timer not found")
        if timer.status == TimerStatus.CANCELLED:
            raise InvalidTransition("That timer was already cancelled")
        timer.status = TimerStatus.CANCELLED


# --------------------------------------------------------------------------- variations


async def save_variation(
    session: AsyncSession, user: User, row: CookingSession, ctx: VersionContext, now: datetime
) -> bool:
    """Replace the caller's private variation for this recipe with the session's swaps."""
    adaptations = await active_adaptations(session, row.id)
    if not adaptations:
        return False
    payload = [
        {
            "id": str(a.id),
            "approved_at": a.approved_at.isoformat(),
            "label": LABELS[a.source],
            "ingredient_ref": a.ingredient_ref,
            "original": a.original,
            "replacement": a.replacement,
            "ratio_or_amount": a.ratio_or_amount,
            "source": a.source,
            "reason": a.reason,
        }
        for a in adaptations
    ]
    stmt = pg_insert(RecipeVariation).values(
        id=uuid.uuid4(),
        owner_user_id=user.id,
        recipe_id=ctx.recipe_id,
        recipe_version_id=ctx.version_id,
        source_session_id=row.id,
        adaptations_json=payload,
        saved_at=now,
        created_at=now,
        updated_at=now,
    )
    stmt = stmt.on_conflict_do_update(
        index_elements=[RecipeVariation.owner_user_id, RecipeVariation.recipe_id],
        set_={
            "recipe_version_id": stmt.excluded.recipe_version_id,
            "source_session_id": stmt.excluded.source_session_id,
            "adaptations_json": stmt.excluded.adaptations_json,
            "saved_at": stmt.excluded.saved_at,
            "updated_at": stmt.excluded.updated_at,
        },
    )
    await session.execute(stmt)
    return True


async def get_variation(
    session: AsyncSession, user: User, version_id: uuid.UUID
) -> tuple[RecipeVariation, list[dict[str, Any]]]:
    """The caller's variation for this version's recipe, keeping only swaps that still apply
    (same ingredient id *and* name in this version). 404 when none apply."""
    ctx = await version_context(session, user, version_id)
    variation = (
        await session.execute(
            select(RecipeVariation).where(
                RecipeVariation.owner_user_id == user.id,
                RecipeVariation.recipe_id == ctx.recipe_id,
            )
        )
    ).scalar_one_or_none()
    if variation is None:
        raise NotFound("No saved changes for this recipe")
    names = {i.id: i.name for i in ctx.ingredients}
    usable = [
        a
        for a in variation.adaptations_json
        if names.get(a.get("ingredient_ref")) == a.get("original")
    ]
    if not usable:
        raise NotFound("No saved changes for this recipe")
    return variation, usable


async def delete_variation(session: AsyncSession, user: User, version_id: uuid.UUID) -> None:
    ctx = await version_context(session, user, version_id)
    variation = (
        await session.execute(
            select(RecipeVariation).where(
                RecipeVariation.owner_user_id == user.id,
                RecipeVariation.recipe_id == ctx.recipe_id,
            )
        )
    ).scalar_one_or_none()
    if variation is not None:
        await session.delete(variation)
        await session.flush()
