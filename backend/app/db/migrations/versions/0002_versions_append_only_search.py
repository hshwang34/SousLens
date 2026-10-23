"""recipe_versions: append-only trigger + search_text (brief 003 / Slice 1)

Revision ID: 0002
Revises: 0001
Create Date: 2026-10-20

* ``recipe_versions.title/summary/tags/cover_image_url``: display metadata snapshot so a version
  is immutable as served; backfilled from ``recipes``.
* ``recipe_versions.search_text``: lowercased ``title + ingredient names`` for the public search
  (REC-02), backfilled from the existing JSON before the trigger is installed.
* ``recipe_versions_immutable``: BEFORE UPDATE OR DELETE trigger that raises on every row
  (PRD §10.1 versioning rule). Escape hatch for operator repairs / account deletion only:
  ``SET LOCAL souslens.unlock_versions = 'on'`` inside the same transaction.
* ``recipe_versions_no_truncate``: statement-level BEFORE TRUNCATE trigger, same unlock.
* ``uq_recipe_drafts_one_open_per_recipe``: partial unique index, one open draft per recipe.
"""
from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = '0002'
down_revision: str | None = '0001'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

TRIGGER_FUNCTION = """
CREATE OR REPLACE FUNCTION recipe_versions_immutable() RETURNS trigger AS $$
BEGIN
    IF coalesce(current_setting('souslens.unlock_versions', true), '') = 'on' THEN
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        END IF;
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'recipe_versions is append-only: % of version % refused', TG_OP, OLD.id
        USING ERRCODE = 'P0001',
              HINT = 'Published versions are immutable; publish a new version instead.';
END
$$ LANGUAGE plpgsql;
"""

TRUNCATE_FUNCTION = """
CREATE OR REPLACE FUNCTION recipe_versions_no_truncate() RETURNS trigger AS $$
BEGIN
    IF coalesce(current_setting('souslens.unlock_versions', true), '') = 'on' THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'recipe_versions is append-only: TRUNCATE refused'
        USING ERRCODE = 'P0001',
              HINT = 'Published versions are immutable; publish a new version instead.';
END
$$ LANGUAGE plpgsql;
"""

BACKFILL_SEARCH_TEXT = """
UPDATE recipe_versions AS v
SET search_text = lower(
    concat_ws(' ', r.title, (
        SELECT string_agg(i->>'name', ' ' ORDER BY ord)
        FROM jsonb_array_elements(v.ingredient_json) WITH ORDINALITY AS t(i, ord)
    ))
)
FROM recipes AS r
WHERE r.id = v.recipe_id
"""


BACKFILL_METADATA = """
UPDATE recipe_versions AS v
SET title = r.title, summary = r.summary, tags = r.tags, cover_image_url = r.cover_image_url
FROM recipes AS r
WHERE r.id = v.recipe_id
"""


def upgrade() -> None:
    op.add_column(
        'recipe_versions',
        sa.Column('search_text', sa.Text(), server_default=sa.text("''"), nullable=False),
    )
    op.add_column('recipe_versions', sa.Column('title', sa.String(length=200), nullable=True))
    op.add_column('recipe_versions', sa.Column('summary', sa.Text(), nullable=True))
    op.add_column(
        'recipe_versions', sa.Column('tags', postgresql.ARRAY(sa.Text()), nullable=True)
    )
    op.add_column('recipe_versions', sa.Column('cover_image_url', sa.Text(), nullable=True))
    # Backfill before the trigger exists (the trigger would refuse these UPDATEs).
    op.execute(BACKFILL_SEARCH_TEXT)
    op.execute(BACKFILL_METADATA)
    op.execute(TRIGGER_FUNCTION)
    op.execute(
        "CREATE TRIGGER recipe_versions_immutable BEFORE UPDATE OR DELETE ON recipe_versions "
        "FOR EACH ROW EXECUTE FUNCTION recipe_versions_immutable()"
    )
    # Row triggers do not fire on TRUNCATE (incl. TRUNCATE ... CASCADE from a parent table).
    op.execute(TRUNCATE_FUNCTION)
    op.execute(
        "CREATE TRIGGER recipe_versions_no_truncate BEFORE TRUNCATE ON recipe_versions "
        "FOR EACH STATEMENT EXECUTE FUNCTION recipe_versions_no_truncate()"
    )
    op.create_index(
        'uq_recipe_drafts_one_open_per_recipe',
        'recipe_drafts',
        ['recipe_id'],
        unique=True,
        postgresql_where=sa.text("status IN ('editing', 'extracting', 'review')"),
    )


def downgrade() -> None:
    op.drop_index('uq_recipe_drafts_one_open_per_recipe', table_name='recipe_drafts')
    op.execute("DROP TRIGGER IF EXISTS recipe_versions_no_truncate ON recipe_versions")
    op.execute("DROP FUNCTION IF EXISTS recipe_versions_no_truncate()")
    op.execute("DROP TRIGGER IF EXISTS recipe_versions_immutable ON recipe_versions")
    op.execute("DROP FUNCTION IF EXISTS recipe_versions_immutable()")
    op.drop_column('recipe_versions', 'cover_image_url')
    op.drop_column('recipe_versions', 'tags')
    op.drop_column('recipe_versions', 'summary')
    op.drop_column('recipe_versions', 'title')
    op.drop_column('recipe_versions', 'search_text')
