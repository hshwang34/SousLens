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
    BigInteger,
    Boolean,
    CheckConstraint,
    DateTime,
    Enum,
    Float,
    ForeignKey,
    Identity,
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


class UserRole(enum.StrEnum):
    COOK = "cook"
    CREATOR = "creator"


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
    LIVE = "live"  # auto-saved from a live pantry scan (brief 016)


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
    # Brief 015: null until the user finishes first-run onboarding.
    onboarded_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    role: Mapped[UserRole | None] = mapped_column(_enum(UserRole, "user_role"))
    # Public creator profile fields (brief 015). Shown on creator pages and follow suggestions.
    bio: Mapped[str | None] = mapped_column(String(280))
    avatar_url: Mapped[str | None] = mapped_column(String(2048))


class Follow(CreatedAtMixin, Base):
    """A user following a creator (brief 015, DECISIONS #27). No followers list or notifications."""

    __tablename__ = "follows"
    __table_args__ = (
        CheckConstraint("follower_id <> creator_id", name="no_self_follow"),
        Index("ix_follows_creator", "creator_id"),
    )

    follower_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    creator_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
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
    ``SET LOCAL umma.unlock_versions = 'on'`` in the same transaction (operator repairs,
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
    """A creator's source video or a rendered step clip (brief 008). Bytes live in object
    storage under ``storage_key``; this row is the only way to get a signed URL for them.

    * ``owner_user_id`` is the creator; every read/write goes through ``get_owned_or_404``
      except the public clip read, which also requires a published, non-private recipe.
    * A source video is kept until the creator deletes it (DECISIONS #20). A clip is attached to
      the first published version that used it (``version_id``); clips that never reached a
      published version are deleted with their draft.
    * ``recipe_id`` is null until the first publish of the draft the media belongs to.
    """

    __tablename__ = "recipe_media"
    __table_args__ = (
        CheckConstraint(
            "status IN ('pending', 'ready', 'failed', 'rejected')", name="status_known"
        ),
        Index("ix_recipe_media_owner_kind", "owner_user_id", "media_kind"),
    )

    id: Mapped[uuid.UUID] = uuid_pk()
    owner_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    recipe_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("recipes.id", ondelete="CASCADE"), nullable=True, index=True
    )
    version_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("recipe_versions.id", ondelete="SET NULL")
    )
    draft_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("recipe_drafts.id", ondelete="SET NULL"), index=True
    )
    # A clip's source video (SET NULL when the creator deletes the source; the clip stays).
    source_media_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("recipe_media.id", ondelete="SET NULL")
    )
    step_id: Mapped[str | None] = mapped_column(String(64))
    media_kind: Mapped[MediaKind] = mapped_column(_enum(MediaKind, "media_kind"), nullable=False)
    status: Mapped[str] = mapped_column(
        String(16), nullable=False, default="pending", server_default=text("'pending'")
    )
    storage_key: Mapped[str] = mapped_column(Text, nullable=False)
    mime_type: Mapped[str | None] = mapped_column(String(100))
    size_bytes: Mapped[int | None] = mapped_column(BigInteger)
    duration_ms: Mapped[int | None] = mapped_column(Integer)
    start_ms: Mapped[int | None] = mapped_column(Integer)
    end_ms: Mapped[int | None] = mapped_column(Integer)
    uploaded_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    consent_record_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("media_consents.id", ondelete="SET NULL")
    )


class MediaDeletion(Base):
    """Transactional outbox for object-storage deletes (brief 008).

    Migration 0008 installs an ``AFTER DELETE`` trigger on ``recipe_media`` that inserts the
    row's ``storage_key`` here, so *every* removal (creator delete, draft delete, recipe or
    account deletion by cascade) queues its object in the same transaction. The extraction
    worker drains it. Code only inserts rows directly for objects that never got a media row.
    """

    __tablename__ = "media_deletions"

    id: Mapped[uuid.UUID] = uuid_pk()
    storage_key: Mapped[str] = mapped_column(Text, nullable=False)
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text("0"))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
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
    """A background job on a creator's video (brief 008): ``extract`` (video → draft + clips)
    or ``trim`` (re-render one step clip); or ``capture`` (a voice capture transcript → draft,
    brief 014). Claimed by the worker with ``FOR UPDATE SKIP
    LOCKED``; ``lease_expires_at`` lets another worker resume it after a crash."""

    __tablename__ = "extraction_jobs"
    __table_args__ = (
        CheckConstraint("kind IN ('extract', 'trim', 'capture')", name="kind_known"),
        # One extraction per uploaded video: marking it uploaded twice returns the same job.
        Index(
            "uq_extraction_jobs_one_extract_per_media",
            "original_media_id",
            unique=True,
            postgresql_where=text("kind = 'extract'"),
        ),
        Index("ix_extraction_jobs_owner_created", "owner_user_id", "created_at"),
    )

    id: Mapped[uuid.UUID] = uuid_pk()
    owner_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    # SET NULL, not CASCADE: a job outlives its draft so deleting a draft can never refund a
    # monthly video extraction (fix round 1).
    draft_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("recipe_drafts.id", ondelete="SET NULL"), nullable=True, index=True
    )
    original_media_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("recipe_media.id", ondelete="SET NULL")
    )
    kind: Mapped[str] = mapped_column(
        String(16), nullable=False, default="extract", server_default=text("'extract'")
    )
    status: Mapped[ExtractionStatus] = mapped_column(
        _enum(ExtractionStatus, "extraction_status"),
        nullable=False,
        default=ExtractionStatus.QUEUED,
        index=True,
    )
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    progress: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default=text("0")
    )
    stage: Mapped[str | None] = mapped_column(String(32))
    error_code: Mapped[str | None] = mapped_column(String(64))
    error_message: Mapped[str | None] = mapped_column(Text)
    # Checkpoints (extraction result, rendered clips, Gemini file name) so a resumed job never
    # pays for the same Gemini call twice and never re-renders a finished clip.
    result_json: Mapped[dict[str, Any] | None] = mapped_column(JSONB)
    params_json: Mapped[dict[str, Any] | None] = mapped_column(JSONB)
    # False when the job ended before any AI spend (bad video, budget refusal): it then does
    # not use up one of the user's monthly video extractions.
    counts_toward_limit: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default=text("true")
    )
    worker_id: Mapped[str | None] = mapped_column(String(64))
    lease_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


CAPTURE_MODES = ("voice", "camera")
CAPTURE_STATUSES = ("recording", "wrapping_up", "generating", "ready", "failed")
CAPTURE_EVENT_KINDS = ("utterance", "question", "answer", "skip", "marker")


def _in(column: str, values: tuple[str, ...]) -> str:
    return f"{column} IN (" + ", ".join(f"'{v}'" for v in values) + ")"


class CaptureSession(TimestampMixin, Base):
    """A voice recipe capture (brief 014): the creator cooks and talks; the interviewer asks
    the odd question; ``generate`` turns the transcript into a draft.

    ``state_json`` is the interviewer's ledger (gaps, questions, budget, quiet/paused), owned
    by ``app.domains.capture.policy``. No audio is ever stored (brief 014 privacy)."""

    __tablename__ = "capture_sessions"
    __table_args__ = (
        CheckConstraint(_in("mode", CAPTURE_MODES), name="mode_known"),
        CheckConstraint(_in("status", CAPTURE_STATUSES), name="status_known"),
        Index(
            "uq_capture_sessions_owner_idempotency_key",
            "owner_user_id",
            "idempotency_key",
            unique=True,
            postgresql_where=text("idempotency_key IS NOT NULL"),
        ),
        Index("ix_capture_sessions_owner_created", "owner_user_id", "created_at"),
    )

    id: Mapped[uuid.UUID] = uuid_pk()
    owner_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    mode: Mapped[str] = mapped_column(String(16), nullable=False)
    status: Mapped[str] = mapped_column(
        String(16), nullable=False, default="recording", server_default=text("'recording'")
    )
    title_hint: Mapped[str | None] = mapped_column(String(120))
    draft_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("recipe_drafts.id", ondelete="SET NULL"), nullable=True, index=True
    )
    extraction_job_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("extraction_jobs.id", ondelete="SET NULL"), nullable=True
    )
    state_json: Mapped[dict[str, Any]] = mapped_column(
        JSONB, nullable=False, default=dict, server_default=text("'{}'::jsonb")
    )
    started_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # Set when the transcript was deleted (draft published or discarded).
    transcript_purged_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # Optional Idempotency-Key on create: a retry returns this session.
    idempotency_key: Mapped[str | None] = mapped_column(String(128))
    request_hash: Mapped[str | None] = mapped_column(String(64))


class CaptureEvent(CreatedAtMixin, Base):
    """One timestamped transcript event. ``t_ms`` is milliseconds since the session started
    (the phone's clock). Deleted with the session, when its draft is published or deleted
    (a trigger on ``recipe_drafts`` covers every delete path), and after 30 idle days."""

    __tablename__ = "capture_events"
    __table_args__ = (
        CheckConstraint(_in("kind", CAPTURE_EVENT_KINDS), name="kind_known"),
        CheckConstraint("t_ms >= 0", name="t_ms_non_negative"),
        UniqueConstraint("session_id", "client_key"),
        Index("ix_capture_events_session_t_ms", "session_id", "t_ms"),
        Index("ix_capture_events_session_seq", "session_id", "seq"),
    )

    id: Mapped[uuid.UUID] = uuid_pk()
    session_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("capture_sessions.id", ondelete="CASCADE"), nullable=False
    )
    t_ms: Mapped[int] = mapped_column(BigInteger, nullable=False)
    kind: Mapped[str] = mapped_column(String(16), nullable=False)
    text: Mapped[str] = mapped_column(Text, nullable=False, default="", server_default=text("''"))
    topic_key: Mapped[str | None] = mapped_column(String(64))
    # An answer / skip / marker about a question points at that question's event.
    question_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("capture_events.id", ondelete="CASCADE"), nullable=True
    )
    # ``<Idempotency-Key>:<n>`` for transcript segments, so a retried batch never duplicates.
    client_key: Mapped[str | None] = mapped_column(String(160))
    # Insertion order. The interviewer tracks what it has seen by ``seq``, never by ``t_ms``
    # (two utterances can share a ``t_ms``).
    seq: Mapped[int] = mapped_column(BigInteger, Identity(), nullable=False)


class CaptureRequest(CreatedAtMixin, Base):
    """Idempotent replay for capture writes: same key + same body → the stored response."""

    __tablename__ = "capture_requests"
    __table_args__ = (UniqueConstraint("session_id", "idempotency_key"),)

    id: Mapped[uuid.UUID] = uuid_pk()
    session_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("capture_sessions.id", ondelete="CASCADE"), nullable=False
    )
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    response_json: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False)


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


LIVE_SCAN_STATUSES = ("scanning", "finished")
LIVE_CONFIDENCES = ("high", "medium", "low")


class PantryLiveScan(CreatedAtMixin, Base):
    """A live pantry scan's basket session (brief 016). 24 h TTL like observations; only
    ``finish`` writes pantry rows. ``demo`` scans (mock provider) never auto-save."""

    __tablename__ = "pantry_live_scans"
    __table_args__ = (
        CheckConstraint(_in("status", LIVE_SCAN_STATUSES), name="status_known"),
        Index("ix_pantry_live_scans_owner_created", "owner_user_id", "created_at"),
    )

    id: Mapped[uuid.UUID] = uuid_pk()
    owner_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    demo: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default=text("false")
    )
    status: Mapped[str] = mapped_column(
        String(16), nullable=False, default="scanning", server_default=text("'scanning'")
    )
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, index=True
    )


class PantryLiveScanItem(CreatedAtMixin, Base):
    """One deduplicated basket item: one row per normalised key per scan."""

    __tablename__ = "pantry_live_scan_items"
    __table_args__ = (
        UniqueConstraint("scan_id", "key"),
        CheckConstraint(_in("confidence", LIVE_CONFIDENCES), name="confidence_known"),
    )

    id: Mapped[uuid.UUID] = uuid_pk()
    scan_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("pantry_live_scans.id", ondelete="CASCADE"), nullable=False
    )
    key: Mapped[str] = mapped_column(String(120), nullable=False)
    display_name: Mapped[str] = mapped_column(String(120), nullable=False)
    kind: Mapped[str | None] = mapped_column(String(32))
    confidence: Mapped[str] = mapped_column(String(8), nullable=False)
    evidence: Mapped[str | None] = mapped_column(Text)


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
    # Brief 015 taste profile: closed vocabularies, soft signals for ranking only.
    diets: Mapped[list[str]] = mapped_column(
        ARRAY(Text), nullable=False, default=list, server_default=text("'{}'")
    )
    cuisines: Mapped[list[str]] = mapped_column(
        ARRAY(Text), nullable=False, default=list, server_default=text("'{}'")
    )
    skill_level: Mapped[str | None] = mapped_column(String(32))
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
    # Optional quantity for byte/amount budgets (brief 008: ``video_upload_bytes``).
    amount: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )


class AIUsage(Base):
    """Gemini spend ledger (brief 007 cost guard).

    One row per guarded provider call. It is inserted as ``reserved`` at the capability's
    worst-case ceiling *before* the call (so concurrent calls see each other), then replaced by
    the price of the reported ``usage_metadata`` (``settled``). A row that is never settled
    keeps counting at its ceiling: a crash can only make the guard stricter.

    ``user_id`` is ``SET NULL`` on delete so deleting an account never refunds the global
    monthly budget. No prompt, image or answer text is stored here.
    """

    __tablename__ = "ai_usage"
    __table_args__ = (
        Index("ix_ai_usage_created", "created_at"),
        Index("ix_ai_usage_user_created", "user_id", "created_at"),
        CheckConstraint("status IN ('reserved', 'settled')", name="status_known"),
    )

    id: Mapped[uuid.UUID] = uuid_pk()
    user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    capability: Mapped[str] = mapped_column(String(32), nullable=False)
    model: Mapped[str] = mapped_column(String(64), nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    reserved_usd: Mapped[Decimal] = mapped_column(Numeric(12, 6), nullable=False)
    cost_usd: Mapped[Decimal | None] = mapped_column(Numeric(12, 6), nullable=True)
    input_tokens: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text("0"))
    output_tokens: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text("0"))
    thinking_tokens: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text("0"))
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text("0"))
    outcome: Mapped[str | None] = mapped_column(String(32), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )
    settled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


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
    RecipeMedia,
    PantryItem,
    PantryObservation,
    CookingSession,
    MediaConsent,
    RecipeVariation,
    SubstitutionSuggestionRecord,
    CaptureSession,
)
