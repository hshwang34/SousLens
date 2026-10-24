"""adaptation warnings and note idempotency (brief 005 fix rounds)

Revision ID: 0005
Revises: 0004
Create Date: 2026-10-24

0004 was already pushed, so these columns land in their own migration:

* ``session_adaptations.allergy_warning`` / ``risks``: the served suggestion's cautions (or the
  ones computed for a free-form swap), so they survive an app relaunch.
* ``session_notes.idempotency_key`` / ``request_hash`` + unique ``(session_id,
  idempotency_key)``: optional Idempotency-Key on ``POST /sessions/{id}/notes``.
"""
from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = '0005'
down_revision: str | None = '0004'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column('session_adaptations', sa.Column('allergy_warning', sa.Text(), nullable=True))
    op.add_column('session_adaptations', sa.Column('risks', postgresql.JSONB(astext_type=sa.Text()), server_default=sa.text("'[]'::jsonb"), nullable=False))
    op.add_column('session_notes', sa.Column('idempotency_key', sa.String(length=128), nullable=True))
    op.add_column('session_notes', sa.Column('request_hash', sa.String(length=64), nullable=True))
    op.create_unique_constraint(op.f('uq_session_notes_session_id_idempotency_key'), 'session_notes', ['session_id', 'idempotency_key'])


def downgrade() -> None:
    op.drop_constraint(op.f('uq_session_notes_session_id_idempotency_key'), 'session_notes', type_='unique')
    op.drop_column('session_notes', 'request_hash')
    op.drop_column('session_notes', 'idempotency_key')
    op.drop_column('session_adaptations', 'risks')
    op.drop_column('session_adaptations', 'allergy_warning')
