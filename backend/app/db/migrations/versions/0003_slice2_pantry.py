"""pantry capture and fit (brief 004 / Slice 2)

Revision ID: 0003
Revises: 0002
Create Date: 2026-10-23

* ``ingredients``: ``qualifiers`` (identity qualifiers the entry implies), ``ambiguous_with``
  (entries a generic name may mean) and ``updated_at`` for the seed upsert.
* ``pantry_items``: ``quantity_is_estimate``, ``note``, ``source_observation_id`` (provenance,
  no FK because observations are purged), CHECKs on ``storage_location`` / ``quantity`` /
  ``confidence``, index ``(owner_user_id, normalized_name)`` for duplicate detection and fit.
  ``source`` value ``transcript`` is renamed ``voice`` (brief 004 contract).
* ``pantry_observations``: ``provider``, ``unknowns_json``, indexes for the TTL purge and the
  per-user rate limit. ``source_image_key`` is **dropped**: images are never stored (PRIV-01).
  ``status`` value ``applied`` is renamed ``confirmed``.
"""
from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = '0003'
down_revision: str | None = '0002'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

STORAGE_LOCATIONS = ("fridge", "freezer", "pantry", "counter", "other")


def upgrade() -> None:
    op.add_column('ingredients', sa.Column('qualifiers', postgresql.ARRAY(sa.Text()), server_default=sa.text("'{}'"), nullable=False))
    op.add_column('ingredients', sa.Column('ambiguous_with', postgresql.ARRAY(sa.Text()), server_default=sa.text("'{}'"), nullable=False))
    op.add_column('ingredients', sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False))

    op.add_column('pantry_items', sa.Column('quantity_is_estimate', sa.Boolean(), server_default=sa.text('false'), nullable=False))
    op.add_column('pantry_items', sa.Column('note', sa.Text(), nullable=True))
    op.add_column('pantry_items', sa.Column('source_observation_id', sa.UUID(), nullable=True))
    op.execute("UPDATE pantry_items SET source = 'voice' WHERE source = 'transcript'")
    allowed = ", ".join(f"'{v}'" for v in STORAGE_LOCATIONS)
    op.execute(
        "UPDATE pantry_items SET storage_location = 'other' "
        f"WHERE storage_location IS NOT NULL AND storage_location NOT IN ({allowed})"
    )
    op.alter_column('pantry_items', 'storage_location',
               existing_type=sa.VARCHAR(length=64),
               type_=sa.String(length=32),
               existing_nullable=True)
    op.create_check_constraint(
        op.f('ck_pantry_items_storage_location_valid'), 'pantry_items',
        f"storage_location IS NULL OR storage_location IN ({allowed})",
    )
    op.create_check_constraint(
        op.f('ck_pantry_items_quantity_non_negative'), 'pantry_items', "quantity IS NULL OR quantity >= 0"
    )
    op.create_check_constraint(
        op.f('ck_pantry_items_confidence_range'), 'pantry_items',
        "confidence IS NULL OR (confidence >= 0 AND confidence <= 1)",
    )
    op.create_index('ix_pantry_items_owner_normalized_name', 'pantry_items', ['owner_user_id', 'normalized_name'], unique=False)

    op.add_column('pantry_observations', sa.Column('provider', sa.String(length=32), server_default=sa.text("'mock'"), nullable=False))
    op.add_column('pantry_observations', sa.Column('unknowns_json', postgresql.JSONB(astext_type=sa.Text()), server_default=sa.text("'[]'::jsonb"), nullable=False))
    op.execute("UPDATE pantry_observations SET status = 'confirmed' WHERE status = 'applied'")
    op.create_index(op.f('ix_pantry_observations_expires_at'), 'pantry_observations', ['expires_at'], unique=False)
    op.create_index('ix_pantry_observations_owner_created', 'pantry_observations', ['owner_user_id', 'created_at'], unique=False)
    op.drop_column('pantry_observations', 'source_image_key')


def downgrade() -> None:
    op.add_column('pantry_observations', sa.Column('source_image_key', sa.TEXT(), autoincrement=False, nullable=True))
    op.drop_index('ix_pantry_observations_owner_created', table_name='pantry_observations')
    op.drop_index(op.f('ix_pantry_observations_expires_at'), table_name='pantry_observations')
    op.execute("UPDATE pantry_observations SET status = 'applied' WHERE status = 'confirmed'")
    op.drop_column('pantry_observations', 'unknowns_json')
    op.drop_column('pantry_observations', 'provider')

    op.drop_index('ix_pantry_items_owner_normalized_name', table_name='pantry_items')
    op.drop_constraint(op.f('ck_pantry_items_confidence_range'), 'pantry_items', type_='check')
    op.drop_constraint(op.f('ck_pantry_items_quantity_non_negative'), 'pantry_items', type_='check')
    op.drop_constraint(op.f('ck_pantry_items_storage_location_valid'), 'pantry_items', type_='check')
    op.alter_column('pantry_items', 'storage_location',
               existing_type=sa.String(length=32),
               type_=sa.VARCHAR(length=64),
               existing_nullable=True)
    op.execute("UPDATE pantry_items SET source = 'transcript' WHERE source = 'voice'")
    op.drop_column('pantry_items', 'source_observation_id')
    op.drop_column('pantry_items', 'note')
    op.drop_column('pantry_items', 'quantity_is_estimate')

    op.drop_column('ingredients', 'updated_at')
    op.drop_column('ingredients', 'ambiguous_with')
    op.drop_column('ingredients', 'qualifiers')
