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
    TRANSCRIPT = "transcript"
    PHOTO = "photo"


class ObservationMode(enum.StrEnum):
    TRANSCRIPT = "transcript"
    PHOTO = "photo"


class ObservationStatus(enum.StrEnum):
    PENDING = "pending"
    APPLIED = "applied"
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


class RecipeDraft(TimestampMixin, Base):
    __tablename__ = "recipe_drafts"

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


class Ingredient(CreatedAtMixin, Base):
    """Controlled dictionary with aliases (scallion = green onion; gochujang ≠ gochugaru)."""

    __tablename__ = "ingredients"

    id: Mapped[uuid.UUID] = uuid_pk()
    canonical_name: Mapped[str] = mapped_column(String(120), nullable=False, unique=True)
    aliases_json: Mapped[list[str]] = mapped_column(JSONB, nullable=False, default=list)
    category: Mapped[str | None] = mapped_column(String(64))
    allergen_flags: Mapped[list[str]] = mapped_column(ARRAY(Text), nullable=False, default=list)


class PantryItem(TimestampMixin, Base):
    __tablename__ = "pantry_items"

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
    storage_location: Mapped[str | None] = mapped_column(String(64))
    source: Mapped[PantrySource] = mapped_column(
        _enum(PantrySource, "pantry_source"), nullable=False
    )
    confidence: Mapped[float | None] = mapped_column(Float)
    last_confirmed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class PantryObservation(CreatedAtMixin, Base):
    """Uncommitted candidates with a short TTL. Never pantry truth."""

    __tablename__ = "pantry_observations"

    id: Mapped[uuid.UUID] = uuid_pk()
    owner_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    mode: Mapped[ObservationMode] = mapped_column(
        _enum(ObservationMode, "observation_mode"), nullable=False
    )
    candidate_json: Mapped[list[Any]] = mapped_column(JSONB, nullable=False, default=list)
    status: Mapped[ObservationStatus] = mapped_column(
        _enum(ObservationStatus, "observation_status"),
        nullable=False,
        default=ObservationStatus.PENDING,
    )
    source_image_key: Mapped[str | None] = mapped_column(Text)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


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
    adaptation_json: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False, default=dict)
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
)
