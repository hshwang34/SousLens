"""Umma rename: the version-unlock setting and the media-deletion trigger function (brief 013)

Revision ID: 0009
Revises: 0008
Create Date: 2026-11-12

Migrations 0002 and 0008 are already applied wherever the database exists, so they keep the
old names as written. This revision moves the live objects to the new ones:

* ``recipe_versions_immutable`` / ``recipe_versions_no_truncate`` now honour
  ``SET LOCAL umma.unlock_versions = 'on'`` (was ``souslens.unlock_versions``). Same bodies,
  only the setting name changes. The old setting no longer unlocks anything.
* ``souslens_queue_media_deletion()`` is renamed ``umma_queue_media_deletion()``. ``ALTER
  FUNCTION ... RENAME`` keeps the trigger bound to it, so nothing is dropped or recreated.
"""
from __future__ import annotations

from collections.abc import Sequence

from alembic import op

revision: str = '0009'
down_revision: str | None = '0008'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def _functions(setting: str) -> list[str]:
    return [
        f"""
CREATE OR REPLACE FUNCTION recipe_versions_immutable() RETURNS trigger AS $$
BEGIN
    IF coalesce(current_setting('{setting}', true), '') = 'on' THEN
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
""",
        f"""
CREATE OR REPLACE FUNCTION recipe_versions_no_truncate() RETURNS trigger AS $$
BEGIN
    IF coalesce(current_setting('{setting}', true), '') = 'on' THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'recipe_versions is append-only: TRUNCATE refused'
        USING ERRCODE = 'P0001',
              HINT = 'Published versions are immutable; publish a new version instead.';
END
$$ LANGUAGE plpgsql;
""",
    ]


def upgrade() -> None:
    for sql in _functions('umma.unlock_versions'):
        op.execute(sql)
    op.execute("ALTER FUNCTION souslens_queue_media_deletion() RENAME TO umma_queue_media_deletion")


def downgrade() -> None:
    op.execute("ALTER FUNCTION umma_queue_media_deletion() RENAME TO souslens_queue_media_deletion")
    for sql in _functions('souslens.unlock_versions'):
        op.execute(sql)
