"""Gemini spend ledger (brief 007 / Slice 4)

Revision ID: 0006
Revises: 0005
Create Date: 2026-10-28

``ai_usage``: one row per guarded AI call, reserved at a worst-case ceiling before the call and
settled at the price of the reported token usage after it. ``user_id`` is SET NULL on delete so
deleting an account never refunds the global monthly budget.
"""
from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op


revision: str = '0006'
down_revision: str | None = '0005'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table('ai_usage',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('user_id', sa.UUID(), nullable=True),
    sa.Column('capability', sa.String(length=32), nullable=False),
    sa.Column('model', sa.String(length=64), nullable=False),
    sa.Column('status', sa.String(length=16), nullable=False),
    sa.Column('reserved_usd', sa.Numeric(precision=12, scale=6), nullable=False),
    sa.Column('cost_usd', sa.Numeric(precision=12, scale=6), nullable=True),
    sa.Column('input_tokens', sa.Integer(), server_default=sa.text('0'), nullable=False),
    sa.Column('output_tokens', sa.Integer(), server_default=sa.text('0'), nullable=False),
    sa.Column('thinking_tokens', sa.Integer(), server_default=sa.text('0'), nullable=False),
    sa.Column('attempts', sa.Integer(), server_default=sa.text('0'), nullable=False),
    sa.Column('outcome', sa.String(length=32), nullable=True),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('settled_at', sa.DateTime(timezone=True), nullable=True),
    sa.CheckConstraint("status IN ('reserved', 'settled')", name=op.f('ck_ai_usage_status_known')),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], name=op.f('fk_ai_usage_user_id_users'), ondelete='SET NULL'),
    sa.PrimaryKeyConstraint('id', name=op.f('pk_ai_usage'))
    )
    op.create_index('ix_ai_usage_created', 'ai_usage', ['created_at'], unique=False)
    op.create_index('ix_ai_usage_user_created', 'ai_usage', ['user_id', 'created_at'], unique=False)


def downgrade() -> None:
    op.drop_index('ix_ai_usage_user_created', table_name='ai_usage')
    op.drop_index('ix_ai_usage_created', table_name='ai_usage')
    op.drop_table('ai_usage')
