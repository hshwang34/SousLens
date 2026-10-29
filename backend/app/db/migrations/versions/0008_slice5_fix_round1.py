"""Brief 008 fix round 1: durable video limits and storage cleanup on every delete

Revision ID: 0008
Revises: 0007
Create Date: 2026-10-29

* ``extraction_jobs.draft_id`` becomes nullable with ``ON DELETE SET NULL``: deleting a draft
  no longer deletes its job, so the monthly extraction count can't be reset that way.
* ``usage_events.amount`` (bytes for the monthly source-upload budget).
* ``AFTER DELETE`` trigger on ``recipe_media`` that queues the object in ``media_deletions``:
  account, recipe and draft deletion (cascades included) never leave objects in storage.
"""
from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op


revision: str = '0008'
down_revision: str | None = '0007'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

FK = 'fk_extraction_jobs_draft_id_recipe_drafts'


def upgrade() -> None:
    op.drop_constraint(FK, 'extraction_jobs', type_='foreignkey')
    op.alter_column('extraction_jobs', 'draft_id', existing_type=sa.UUID(), nullable=True)
    op.create_foreign_key(
        FK, 'extraction_jobs', 'recipe_drafts', ['draft_id'], ['id'], ondelete='SET NULL'
    )
    op.add_column('usage_events', sa.Column('amount', sa.BigInteger(), nullable=True))
    op.execute(
        """
        CREATE FUNCTION souslens_queue_media_deletion() RETURNS trigger AS $$
        BEGIN
            INSERT INTO media_deletions (id, storage_key, attempts, created_at)
            VALUES (gen_random_uuid(), OLD.storage_key, 0, now());
            RETURN OLD;
        END;
        $$ LANGUAGE plpgsql
        """
    )
    op.execute(
        "CREATE TRIGGER recipe_media_queue_deletion AFTER DELETE ON recipe_media "
        "FOR EACH ROW EXECUTE FUNCTION souslens_queue_media_deletion()"
    )


def downgrade() -> None:
    op.execute("DROP TRIGGER IF EXISTS recipe_media_queue_deletion ON recipe_media")
    op.execute("DROP FUNCTION IF EXISTS souslens_queue_media_deletion()")
    op.drop_column('usage_events', 'amount')
    op.execute("DELETE FROM extraction_jobs WHERE draft_id IS NULL")
    op.drop_constraint(FK, 'extraction_jobs', type_='foreignkey')
    op.alter_column('extraction_jobs', 'draft_id', existing_type=sa.UUID(), nullable=False)
    op.create_foreign_key(
        FK, 'extraction_jobs', 'recipe_drafts', ['draft_id'], ['id'], ondelete='CASCADE'
    )
