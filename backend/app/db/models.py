"""SQLAlchemy 2 models for every PRD §10 table.

Rules: UUID primary keys, timezone-aware UTC timestamps, JSONB for ``*_json`` columns, and
``owner_user_id`` on every owned resource. No media bytes live here (storage keys only).
"""

from __future__ import annotations

import enum
import uuid
from datetime import datetime
from decimal import Decimal
from typing import Any

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    Enum,
    Float,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    Text,
    UniqueConstraint,
    text,
)
from sqlalchemy.dialects.postgresql import ARRAY, JSONB
from sqlalchemy.dialects.postgresql import UUID as PG_UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, CreatedAtMixin, TimestampMixin, uuid_pk


def _enum(enum_cls: type[enum.Enum], name: str) -> Enum:
    # Stored as VARCHAR (portable, no ALTER TYPE dance on every new value).
    return Enum(enum_cls, name=name, native_enum=False, length=32, values_callable=_values)


def _values(enum_cls: type[enum.Enum]) -> list[str]:
    return [str(member.value) for member in enum_cls]


class PreferenceUnits(enum.StrEnum):
    US = "us"
    METRIC = "metric"


class Visibility(enum.StrEnum):
    PUBLIC = "public"
    PRIVATE = "private"
    UNLISTED = "unlisted"


class MediaKind(enum.StrEnum):
    SOURCE_VIDEO = "source_video"
    STEP_CLIP = "step_clip"
    COVER_IMAGE = "cover_image"


class DraftStatus(enum.StrEnum):
    EDITING = "editing"
    EXTRACTING = "extracting"
    REVIEW = "review"
    PUBLISHED = "published"
    DISCARDED = "discarded"


class ExtractionStatus(enum.StrEnum):
    QUEUED = "queued"
    WORKING = "working"
    REVIEW = "review"
    FAILED = "failed"


class PantrySource(enum.StrEnum):
    MANUAL = "manual"
    VOICE = "voice"
    PHOTO = "photo"


class StorageLocation(enum.StrEnum):
    FRIDGE = "fridge"
    FREEZER = "freezer"
    PANTRY = "pantry"
    COUNTER = "counter"
    OTHER = "other"


class ObservationMode(enum.StrEnum):
    TRANSCRIPT = "transcript"
    PHOTO = "photo"


class ObservationStatus(enum.StrEnum):
    # pending_provider: rate-limit slot reserved, provider call in flight (no candidates yet).
    # failed: the provider call failed; the row still counts toward the hourly limit and is
    # purged by the 24 h TTL like any other.
    PENDING_PROVIDER = "pending_provider"
    FAILED = "failed"
    PENDING = "pending"
    CONFIRMED = "confirmed"
    DISCARDED = "discarded"
    EXPIRED = "expired"


class SessionStatus(enum.StrEnum):
    CREATED = "created"
    ACTIVE = "active"
    PAUSED = "paused"
    COMPLETED = "completed"
    ABANDONED = "abandoned"


class MessageRole(enum.StrEnum):
    USER = "user"
    ASSISTANT = "assistant"
    SYSTEM = "system"


class TimerStatus(enum.StrEnum):
    RUNNING = "running"
    PAUSED = "paused"
    FIRED = "fired"
    CANCELLED = "cancelled"


class User(TimestampMixin, Base):
    __tablename__ = "users"
    __table_args__ = (UniqueConstraint("auth_provider", "auth_subject"),)

    id: Mapped[uuid.UUID] = uuid_pk()
    auth_provider: Mapped[str] = mapped_column(String(32), nullable=False)
    auth_subject: Mapped[str] = mapped_column(String(320), nullable=False)
    email: Mapped[str | None] = mapped_column(String(320), unique=True)
    display_name: Mapped[str] = mapped_column(String(120), nullable=False)
    preference_units: Mapped[PreferenceUnits] = mapped_column(
        _enum(PreferenceUnits, "preference_units"), nullable=False, default=PreferenceUnits.US
    )


class DevLoginChallenge(CreatedAtMixin, Base):
    """One-time sign-in code for the dev auth provider (DECISIONS #5). Dev mode only.

    The code itself is never stored: ``code_hash`` is an HMAC keyed with the server secret.
    """

    __tablename__ = "dev_login_challenges"
    __table_args__ = (CheckConstraint("attempts >= 0", name="attempts_non_negative"),)

    id: Mapped[uuid.UUID] = uuid_pk()
    email: Mapped[str] = mapped_column(String(320), nullable=False, index=True)
    code_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Recipe(TimestampMixin, Base):
    """Mutable recipe metadata. Content lives in immutable ``recipe_versions``."""

    __tablename__ = "recipes"
    __table_args__ = (Index("ix_recipes_public_feed", "visibility", "published_at", "id"),)

    id: Mapped[uuid.UUID] = uuid_pk()
    owner_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    slug: Mapped[str] = mapped_column(String(160), nullable=False, unique=True)
    visibility: Mapped[Visibility] = mapped_column(
        _enum(Visibility, "visibility"), nullable=False, default=Visibility.PRIVATE
    )
    title: Mapped[str] = mapped_column(String(200), nullable=False)
    summary: Mapped[str | None] = mapped_column(Text)
    tags: Mapped[list[str]] = mapped_column(ARRAY(Text), nullable=False, default=list)
    cover_image_url: Mapped[str | None] = mapped_column(Text)
    latest_version_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("recipe_versions.id", use_alter=True, ondelete="SET NULL")
    )
    published_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    owner: Mapped[User] = relationship(foreign_keys=[owner_user_id], lazy="joined")
    latest_version: Mapped[RecipeVersion | None] = relationship(
        foreign_keys=[latest_version_id], post_update=True, lazy="joined"
    )


class RecipeVersion(CreatedAtMixin, Base):
    """Immutable once published (PRD §10.1 versioning rule).

    Append-only at the database level: migration 0002 installs a ``BEFORE UPDATE OR DELETE``
    trigger that raises on every row. The only escape hatch is an explicit
    ``SET LOCAL souslens.unlock_versions = 'on'`` in the same transaction (operator repairs,
    account deletion flows); application code never sets it.

    ``title``/``summary``/``tags``/``cover_image_url`` are snapshotted too, so
    ``GET /recipe-versions/{id}`` is byte-identical for the life of the row.

    ``search_text`` is a denormalised, lowercased ``title + ingredient names`` string written at
    publish time so the public search can match ingredients with a plain ILIKE (REC-02).
    """

    __tablename__ = "recipe_versions"
    __table_args__ = (UniqueConstraint("recipe_id", "version_number"),)

    id: Mapped[uuid.UUID] = uuid_pk()
    recipe_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("recipes.id", ondelete="CASCADE"), nullable=False, index=True
    )
    version_number: Mapped[int] = mapped_column(Integer, nullable=False)
    servings: Mapped[int] = mapped_column(Integer, nullable=False)
    prep_minutes: Mapped[int | None] = mapped_column(Integer)
    cook_minutes: Mapped[int | None] = mapped_column(Integer)
    ingredient_json: Mapped[list[Any]] = mapped_column(JSONB, nullable=False, default=list)
    step_json: Mapped[list[Any]] = mapped_column(JSONB, nullable=False, default=list)
    warning_json: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False, default=dict)
    search_text: Mapped[str] = mapped_column(
        Text, nullable=False, default="", server_default=text("''")
    )
    # Display metadata snapshotted at publish so a version is immutable *as served*. Nullable
    # only for rows written before migration 0002 (backfilled) and ad-hoc test rows; readers
    # fall back to the mutable ``recipes`` columns when null. ``recipes.title/summary/tags/
    # cover_image_url`` stay as listing/search metadata, mirrored from the latest publish.
    title: Mapped[str | None] = mapped_column(String(200))
    summary: Mapped[str | None] = mapped_column(Text)
    tags: Mapped[list[str] | None] = mapped_column(ARRAY(Text))
    cover_image_url: Mapped[str | None] = mapped_column(Text)
    source_video_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("recipe_media.id", use_alter=True, ondelete="SET NULL")
    )


class RecipeMedia(CreatedAtMixin, Base):
    __tablename__ = "recipe_media"

    id: Mapped[uuid.UUID] = uuid_pk()
    recipe_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("recipes.id", ondelete="CASCADE"), nullable=False, index=True
    )
    version_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("recipe_versions.id", ondelete="SET NULL")
    )
    media_kind: Mapped[MediaKind] = mapped_column(_enum(MediaKind, "media_kind"), nullable=False)
    storage_key: Mapped[str] = mapped_column(Text, nullable=False)
    mime_type: Mapped[str | None] = mapped_column(String(100))
    start_ms: Mapped[int | None] = mapped_column(Integer)
    end_ms: Mapped[int | None] = mapped_column(Integer)
    consent_record_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("media_consents.id", ondelete="SET NULL")
    )


OPEN_DRAFT_STATUS_VALUES = ("editing", "extracting", "review")


class RecipeDraft(TimestampMixin, Base):
    __tablename__ = "recipe_drafts"
    __table_args__ = (
        # At most one open (editing/extracting/review) draft per published recipe (REC-06).
        Index(
            "uq_recipe_drafts_one_open_per_recipe",
            "recipe_id",
            unique=True,
            postgresql_where=text(
                "status IN (" + ", ".join(f"'{s}'" for s in OPEN_DRAFT_STATUS_VALUES) + ")"
            ),
        ),
    )

    id: Mapped[uuid.UUID] = uuid_pk()
    owner_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    recipe_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("recipes.id", ondelete="SET NULL")
    )
    structured_draft_json: Mapped[dict[str, Any]] = mapped_column(
        JSONB, nullable=False, default=dict
    )
    status: Mapped[DraftStatus] = mapped_column(
        _enum(DraftStatus, "draft_status"), nullable=False, default=DraftStatus.EDITING
    )


class ExtractionJob(TimestampMixin, Base):
    __tablename__ = "extraction_jobs"

    id: Mapped[uuid.UUID] = uuid_pk()
    owner_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    draft_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("recipe_drafts.id", ondelete="CASCADE"), nullable=False, index=True
    )
    original_media_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("recipe_media.id", ondelete="SET NULL")
    )
    status: Mapped[ExtractionStatus] = mapped_column(
        _enum(ExtractionStatus, "extraction_status"),
        nullable=False,
        default=ExtractionStatus.QUEUED,
        index=True,
    )
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    error_code: Mapped[str | None] = mapped_column(String(64))
    result_json: Mapped[dict[str, Any] | None] = mapped_column(JSONB)


class Save(CreatedAtMixin, Base):
    __tablename__ = "saves"
    __table_args__ = (UniqueConstraint("user_id", "recipe_id"),)

    id: Mapped[uuid.UUID] = uuid_pk()
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    recipe_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("recipes.id", ondelete="CASCADE"), nullable=False, index=True
    )


class Ingredient(TimestampMixin, Base):
    """Controlled dictionary with aliases (scallion = green onion; gochujang ≠ gochugaru).

    Seeded from ``fixtures/ingredients.json`` by ``make seed`` (upsert by ``canonical_name``).
    ``qualifiers`` are the identity qualifiers the entry implies (``cooked`` for cooked rice,
    ``fresh`` for cilantro); a name carrying any other identity qualifier never resolves to it.
    ``ambiguous_with`` lists entries a generic name may mean ("chicken" → chicken thigh), which
    recipe fit reports as uncertain rather than available.
    """

    __tablename__ = "ingredients"

    id: Mapped[uuid.UUID] = uuid_pk()
    canonical_name: Mapped[str] = mapped_column(String(120), nullable=False, unique=True)
    aliases_json: Mapped[list[str]] = mapped_column(JSONB, nullable=False, default=list)
    category: Mapped[str | None] = mapped_column(String(64))
    allergen_flags: Mapped[list[str]] = mapped_column(ARRAY(Text), nullable=False, default=list)
    qualifiers: Mapped[list[str]] = mapped_column(
        ARRAY(Text), nullable=False, default=list, server_default=text("'{}'")
    )
    ambiguous_with: Mapped[list[str]] = mapped_column(
        ARRAY(Text), nullable=False, default=list, server_default=text("'{}'")
    )


STORAGE_LOCATION_VALUES = tuple(str(m.value) for m in StorageLocation)


class PantryItem(TimestampMixin, Base):
    """User-confirmed pantry truth (PAN-01/05). Only written after explicit confirmation."""

    __tablename__ = "pantry_items"
    __table_args__ = (
        Index("ix_pantry_items_owner_normalized_name", "owner_user_id", "normalized_name"),
        CheckConstraint(
            "storage_location IS NULL OR storage_location IN ("
            + ", ".join(f"'{v}'" for v in STORAGE_LOCATION_VALUES)
            + ")",
            name="storage_location_valid",
        ),
        CheckConstraint("quantity IS NULL OR quantity >= 0", name="quantity_non_negative"),
        CheckConstraint(
            "confidence IS NULL OR (confidence >= 0 AND confidence <= 1)",
            name="confidence_range",
        ),
    )

    id: Mapped[uuid.UUID] = uuid_pk()
    owner_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    ingredient_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("ingredients.id", ondelete="SET NULL")
    )
    raw_label: Mapped[str] = mapped_column(String(200), nullable=False)
    normalized_name: Mapped[str] = mapped_column(String(120), nullable=False)
    quantity: Mapped[Decimal | None] = mapped_column(Numeric(12, 3))
    unit: Mapped[str | None] = mapped_column(String(32))
    quantity_is_estimate: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default=text("false")
    )
    storage_location: Mapped[str | None] = mapped_column(String(32))
    note: Mapped[str | None] = mapped_column(Text)
    source: Mapped[PantrySource] = mapped_column(
        _enum(PantrySource, "pantry_source"), nullable=False
    )
    confidence: Mapped[float | None] = mapped_column(Float)
    # Provenance only (no FK): observation rows are purged after 24 h, the link outlives them.
    source_observation_id: Mapped[uuid.UUID | None] = mapped_column(PG_UUID(as_uuid=True))
    last_confirmed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class PantryObservation(CreatedAtMixin, Base):
    """Uncommitted candidates with a 24 h TTL. Never pantry truth, and never an image: only the
    candidate JSON is stored (PRIV-01, PRD §13.2)."""

    __tablename__ = "pantry_observations"
    __table_args__ = (Index("ix_pantry_observations_owner_created", "owner_user_id", "created_at"),)

    id: Mapped[uuid.UUID] = uuid_pk()
    owner_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    mode: Mapped[ObservationMode] = mapped_column(
        _enum(ObservationMode, "observation_mode"), nullable=False
    )
    provider: Mapped[str] = mapped_column(
        String(32), nullable=False, default="mock", server_default=text("'mock'")
    )
    candidate_json: Mapped[list[Any]] = mapped_column(JSONB, nullable=False, default=list)
    unknowns_json: Mapped[list[Any]] = mapped_column(
        JSONB, nullable=False, default=list, server_default=text("'[]'::jsonb")
    )
    status: Mapped[ObservationStatus] = mapped_column(
        _enum(ObservationStatus, "observation_status"),
        nullable=False,
        default=ObservationStatus.PENDING,
    )
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, index=True
    )


class CookingSession(TimestampMixin, Base):
    """Authoritative session state; only the Step Oracle mutates status/step_index/revision."""

    __tablename__ = "cooking_sessions"
    __table_args__ = (
        CheckConstraint("step_index >= 0", name="step_index_non_negative"),
        CheckConstraint("revision >= 0", name="revision_non_negative"),
    )

    id: Mapped[uuid.UUID] = uuid_pk()
    owner_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    recipe_version_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("recipe_versions.id", ondelete="RESTRICT"), nullable=False, index=True
    )
    status: Mapped[SessionStatus] = mapped_column(
        _enum(SessionStatus, "session_status"), nullable=False, default=SessionStatus.CREATED
    )
    step_index: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    revision: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    pantry_snapshot_json: Mapped[list[Any]] = mapped_column(JSONB, nullable=False, default=list)
    # Session step overlay (brief 005): ``{"steps": {step_id: {"instruction", "adaptation_ids"}}}``,
    # recomputed deterministically from the active ``session_adaptations`` on every approve /
    # revert, so reads never depend on the (mutable) dictionary. The pinned version is untouched.
    adaptation_json: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False, default=dict)
    # ``{"result": "cooked|partly|didnt_work", "saved_changes": bool}`` once completed (COOK-08).
    outcome_json: Mapped[dict[str, Any] | None] = mapped_column(JSONB)
    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class SessionEvent(CreatedAtMixin, Base):
    """Append-only command log. ``idempotency_key`` is unique per session."""

    __tablename__ = "session_events"
    __table_args__ = (
        UniqueConstraint("session_id", "idempotency_key"),
        UniqueConstraint("session_id", "sequence"),
        CheckConstraint("sequence >= 0", name="sequence_non_negative"),
    )

    id: Mapped[uuid.UUID] = uuid_pk()
    session_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("cooking_sessions.id", ondelete="CASCADE"), nullable=False, index=True
    )
    sequence: Mapped[int] = mapped_column(Integer, nullable=False)
    type: Mapped[str] = mapped_column(String(64), nullable=False)
    payload_json: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False, default=dict)
    idempotency_key: Mapped[str | None] = mapped_column(String(128))
    # Idempotent replay (oracle.py contract): sha256 of the canonical command body, and the exact
    # Session JSON returned the first time. Same key + same hash → replay; different hash → 409.
    request_hash: Mapped[str | None] = mapped_column(String(64))
    response_json: Mapped[dict[str, Any] | None] = mapped_column(JSONB)


class SessionMessage(CreatedAtMixin, Base):
    __tablename__ = "session_messages"

    id: Mapped[uuid.UUID] = uuid_pk()
    session_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("cooking_sessions.id", ondelete="CASCADE"), nullable=False, index=True
    )
    role: Mapped[MessageRole] = mapped_column(_enum(MessageRole, "message_role"), nullable=False)
    text: Mapped[str] = mapped_column(Text, nullable=False)
    grounded_step_index: Mapped[int | None] = mapped_column(Integer)
    grounded_revision: Mapped[int | None] = mapped_column(Integer)
    source_refs_json: Mapped[list[Any]] = mapped_column(JSONB, nullable=False, default=list)


class Timer(CreatedAtMixin, Base):
    """Absolute ``target_at`` deadline so timers survive app restarts (COOK-06)."""

    __tablename__ = "timers"
    __table_args__ = (CheckConstraint("step_index >= 0", name="step_index_non_negative"),)

    id: Mapped[uuid.UUID] = uuid_pk()
    session_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("cooking_sessions.id", ondelete="CASCADE"), nullable=False, index=True
    )
    step_index: Mapped[int] = mapped_column(Integer, nullable=False)
    label: Mapped[str] = mapped_column(String(120), nullable=False)
    target_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    status: Mapped[TimerStatus] = mapped_column(
        _enum(TimerStatus, "timer_status"), nullable=False, default=TimerStatus.RUNNING
    )


class SessionAdaptation(CreatedAtMixin, Base):
    """An approved swap in one session's overlay (SUB-03/04). Reverting sets ``reverted_at``;
    the row stays for the audit trail. At most one active adaptation per ingredient."""

    __tablename__ = "session_adaptations"
    __table_args__ = (
        Index(
            "uq_session_adaptations_active_ref",
            "session_id",
            "ingredient_ref",
            unique=True,
            postgresql_where=text("reverted_at IS NULL"),
        ),
        CheckConstraint("source IN ('rule', 'ai')", name="source_valid"),
    )

    id: Mapped[uuid.UUID] = uuid_pk()
    session_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("cooking_sessions.id", ondelete="CASCADE"), nullable=False, index=True
    )
    ingredient_ref: Mapped[str] = mapped_column(String(64), nullable=False)
    original: Mapped[str] = mapped_column(String(200), nullable=False)
    replacement: Mapped[str] = mapped_column(String(200), nullable=False)
    ratio_or_amount: Mapped[str | None] = mapped_column(String(200))
    source: Mapped[str] = mapped_column(String(16), nullable=False)
    reason: Mapped[str | None] = mapped_column(String(300))
    suggestion_id: Mapped[uuid.UUID | None] = mapped_column(PG_UUID(as_uuid=True))
    # Copied from the served suggestion on approve (null / [] for free-form swaps), so the
    # cautions survive an app relaunch.
    allergy_warning: Mapped[str | None] = mapped_column(Text)
    risks: Mapped[list[Any]] = mapped_column(
        JSONB, nullable=False, default=list, server_default=text("'[]'::jsonb")
    )
    approved_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    reverted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class SessionNote(CreatedAtMixin, Base):
    """Private reflection on a session (COOK-08)."""

    __tablename__ = "session_notes"
    __table_args__ = (UniqueConstraint("session_id", "idempotency_key"),)

    id: Mapped[uuid.UUID] = uuid_pk()
    session_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("cooking_sessions.id", ondelete="CASCADE"), nullable=False, index=True
    )
    text: Mapped[str] = mapped_column(Text, nullable=False)
    # Optional Idempotency-Key: a retry returns this note; a different body is a 409.
    idempotency_key: Mapped[str | None] = mapped_column(String(128))
    request_hash: Mapped[str | None] = mapped_column(String(64))


class UserPreference(Base):
    """Food allergies (hard blocks) and foods to avoid (soft), normalised (SUB-02)."""

    __tablename__ = "user_preferences"

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    allergies: Mapped[list[str]] = mapped_column(ARRAY(Text), nullable=False, default=list)
    avoid: Mapped[list[str]] = mapped_column(ARRAY(Text), nullable=False, default=list)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )


class RecipeVariation(TimestampMixin, Base):
    """A learner's private change set for a recipe (COOK-08). One per user + recipe; a new
    save replaces it. Never public (SUB-06 is P1)."""

    __tablename__ = "recipe_variations"
    __table_args__ = (UniqueConstraint("owner_user_id", "recipe_id"),)

    id: Mapped[uuid.UUID] = uuid_pk()
    owner_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    recipe_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("recipes.id", ondelete="CASCADE"), nullable=False, index=True
    )
    recipe_version_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("recipe_versions.id", ondelete="CASCADE"), nullable=False
    )
    source_session_id: Mapped[uuid.UUID | None] = mapped_column(PG_UUID(as_uuid=True))
    adaptations_json: Mapped[list[Any]] = mapped_column(JSONB, nullable=False, default=list)
    saved_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class SubstitutionRule(TimestampMixin, Base):
    """Vetted seed swaps from ``fixtures/substitution_rules.json`` (PRD §12.3), upserted by
    ``make seed`` keyed on the dictionary canonical name."""

    __tablename__ = "substitution_rules"

    id: Mapped[uuid.UUID] = uuid_pk()
    target: Mapped[str] = mapped_column(String(120), nullable=False, unique=True)
    rule_json: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False, default=dict)


class SubstitutionSuggestionRecord(CreatedAtMixin, Base):
    """A suggestion as served, so ``approve`` can reference it by ``suggestion_id`` without the
    client re-sending (and possibly altering) its content. 24 h TTL."""

    __tablename__ = "substitution_suggestions"
    __table_args__ = (
        Index("ix_substitution_suggestions_owner_created", "owner_user_id", "created_at"),
    )

    id: Mapped[uuid.UUID] = uuid_pk()
    owner_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    recipe_version_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("recipe_versions.id", ondelete="CASCADE"), nullable=False
    )
    ingredient_ref: Mapped[str] = mapped_column(String(64), nullable=False)
    payload_json: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False, default=dict)
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, index=True
    )


class UsageEvent(Base):
    """Durable per-user usage ledger for rate limits (``ask``, ``session_created``).

    Deliberately not linked to sessions: deleting or recreating a session must never reset a
    budget (brief 005 security review).
    """

    __tablename__ = "usage_events"
    __table_args__ = (Index("ix_usage_events_user_kind_created", "user_id", "kind", "created_at"),)

    id: Mapped[uuid.UUID] = uuid_pk()
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    kind: Mapped[str] = mapped_column(String(32), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )


class MediaConsent(Base):
    __tablename__ = "media_consents"

    id: Mapped[uuid.UUID] = uuid_pk()
    owner_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    content_id: Mapped[uuid.UUID] = mapped_column(PG_UUID(as_uuid=True), nullable=False, index=True)
    consent_type: Mapped[str] = mapped_column(String(64), nullable=False)
    captured_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    withdrawn_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    confirmed_rights: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)


class Feedback(CreatedAtMixin, Base):
    __tablename__ = "feedback"

    id: Mapped[uuid.UUID] = uuid_pk()
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    session_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("cooking_sessions.id", ondelete="SET NULL")
    )
    category: Mapped[str] = mapped_column(String(64), nullable=False)
    severity: Mapped[str] = mapped_column(String(32), nullable=False)
    details: Mapped[str] = mapped_column(Text, nullable=False)


OWNED_TABLES: tuple[type[Base], ...] = (
    Recipe,
    RecipeDraft,
    ExtractionJob,
    PantryItem,
    PantryObservation,
    CookingSession,
    MediaConsent,
    RecipeVariation,
    SubstitutionSuggestionRecord,
)
