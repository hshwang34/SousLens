"""Onboarding state, creator profile fields, taste preferences and follows (brief 015)

Revision ID: 0010
Revises: 0009
Create Date: 2026-11-13

All additive. Existing users keep ``onboarded_at = NULL`` (they see onboarding once) and get
empty ``diets``/``cuisines`` via the server default.

"""
from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = '0010'
down_revision: str | None = '0009'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table('follows',
    sa.Column('follower_id', sa.UUID(), nullable=False),
    sa.Column('creator_id', sa.UUID(), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.CheckConstraint('follower_id <> creator_id', name=op.f('ck_follows_no_self_follow')),
    sa.ForeignKeyConstraint(['creator_id'], ['users.id'], name=op.f('fk_follows_creator_id_users'), ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['follower_id'], ['users.id'], name=op.f('fk_follows_follower_id_users'), ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('follower_id', 'creator_id', name=op.f('pk_follows'))
    )
    op.create_index('ix_follows_creator', 'follows', ['creator_id'], unique=False)
    op.add_column('user_preferences', sa.Column('diets', postgresql.ARRAY(sa.Text()), server_default=sa.text("'{}'"), nullable=False))
    op.add_column('user_preferences', sa.Column('cuisines', postgresql.ARRAY(sa.Text()), server_default=sa.text("'{}'"), nullable=False))
    op.add_column('user_preferences', sa.Column('skill_level', sa.String(length=32), nullable=True))
    op.add_column('users', sa.Column('onboarded_at', sa.DateTime(timezone=True), nullable=True))
    op.add_column('users', sa.Column('role', sa.Enum('cook', 'creator', name='user_role', native_enum=False, length=32), nullable=True))
    op.add_column('users', sa.Column('bio', sa.String(length=280), nullable=True))
    op.add_column('users', sa.Column('avatar_url', sa.String(length=2048), nullable=True))


def downgrade() -> None:
    op.drop_column('users', 'avatar_url')
    op.drop_column('users', 'bio')
    op.drop_column('users', 'role')
    op.drop_column('users', 'onboarded_at')
    op.drop_column('user_preferences', 'skill_level')
    op.drop_column('user_preferences', 'cuisines')
    op.drop_column('user_preferences', 'diets')
    op.drop_index('ix_follows_creator', table_name='follows')
    op.drop_table('follows')
