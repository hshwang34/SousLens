"""substitutions and cooking engine (brief 005 / Slice 3)

Revision ID: 0004
Revises: 0003
Create Date: 2026-10-23

* ``user_preferences``: normalised allergies (hard blocks) and foods to avoid (SUB-02).
* ``substitution_rules``: vetted seed swaps (``fixtures/substitution_rules.json``, upserted by
  ``make seed``); ``substitution_suggestions``: suggestions as served, 24 h TTL, referenced by
  ``suggestion_id`` on approve.
* ``session_adaptations`` (one active per ingredient, partial unique index) and
  ``session_notes``; ``cooking_sessions.outcome_json``.
* ``recipe_variations``: one private change set per user + recipe (COOK-08).
* ``session_events.request_hash`` / ``response_json``: idempotent command replay.
* ``usage_events``: durable per-user ledger for the ask / session-creation rate limits (not
  linked to sessions, so deleting a session never resets a budget).
"""
from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = '0004'
down_revision: str | None = '0003'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table('substitution_rules',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('target', sa.String(length=120), nullable=False),
    sa.Column('rule_json', postgresql.JSONB(astext_type=sa.Text()), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('id', name=op.f('pk_substitution_rules')),
    sa.UniqueConstraint('target', name=op.f('uq_substitution_rules_target'))
    )
    op.create_table('user_preferences',
    sa.Column('user_id', sa.UUID(), nullable=False),
    sa.Column('allergies', postgresql.ARRAY(sa.Text()), nullable=False),
    sa.Column('avoid', postgresql.ARRAY(sa.Text()), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], name=op.f('fk_user_preferences_user_id_users'), ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('user_id', name=op.f('pk_user_preferences'))
    )
    op.create_table('recipe_variations',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('owner_user_id', sa.UUID(), nullable=False),
    sa.Column('recipe_id', sa.UUID(), nullable=False),
    sa.Column('recipe_version_id', sa.UUID(), nullable=False),
    sa.Column('source_session_id', sa.UUID(), nullable=True),
    sa.Column('adaptations_json', postgresql.JSONB(astext_type=sa.Text()), nullable=False),
    sa.Column('saved_at', sa.DateTime(timezone=True), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['owner_user_id'], ['users.id'], name=op.f('fk_recipe_variations_owner_user_id_users'), ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['recipe_id'], ['recipes.id'], name=op.f('fk_recipe_variations_recipe_id_recipes'), ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['recipe_version_id'], ['recipe_versions.id'], name=op.f('fk_recipe_variations_recipe_version_id_recipe_versions'), ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id', name=op.f('pk_recipe_variations')),
    sa.UniqueConstraint('owner_user_id', 'recipe_id', name=op.f('uq_recipe_variations_owner_user_id_recipe_id'))
    )
    op.create_index(op.f('ix_recipe_variations_owner_user_id'), 'recipe_variations', ['owner_user_id'], unique=False)
    op.create_index(op.f('ix_recipe_variations_recipe_id'), 'recipe_variations', ['recipe_id'], unique=False)
    op.create_table('substitution_suggestions',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('owner_user_id', sa.UUID(), nullable=False),
    sa.Column('recipe_version_id', sa.UUID(), nullable=False),
    sa.Column('ingredient_ref', sa.String(length=64), nullable=False),
    sa.Column('payload_json', postgresql.JSONB(astext_type=sa.Text()), nullable=False),
    sa.Column('expires_at', sa.DateTime(timezone=True), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['owner_user_id'], ['users.id'], name=op.f('fk_substitution_suggestions_owner_user_id_users'), ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['recipe_version_id'], ['recipe_versions.id'], name=op.f('fk_substitution_suggestions_recipe_version_id_recipe_versions'), ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id', name=op.f('pk_substitution_suggestions'))
    )
    op.create_index(op.f('ix_substitution_suggestions_expires_at'), 'substitution_suggestions', ['expires_at'], unique=False)
    op.create_index('ix_substitution_suggestions_owner_created', 'substitution_suggestions', ['owner_user_id', 'created_at'], unique=False)
    op.create_index(op.f('ix_substitution_suggestions_owner_user_id'), 'substitution_suggestions', ['owner_user_id'], unique=False)
    op.create_table('session_adaptations',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('session_id', sa.UUID(), nullable=False),
    sa.Column('ingredient_ref', sa.String(length=64), nullable=False),
    sa.Column('original', sa.String(length=200), nullable=False),
    sa.Column('replacement', sa.String(length=200), nullable=False),
    sa.Column('ratio_or_amount', sa.String(length=200), nullable=True),
    sa.Column('source', sa.String(length=16), nullable=False),
    sa.Column('reason', sa.String(length=300), nullable=True),
    sa.Column('suggestion_id', sa.UUID(), nullable=True),
    sa.Column('approved_at', sa.DateTime(timezone=True), nullable=False),
    sa.Column('reverted_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['session_id'], ['cooking_sessions.id'], name=op.f('fk_session_adaptations_session_id_cooking_sessions'), ondelete='CASCADE'),
    sa.CheckConstraint("source IN ('rule', 'ai')", name=op.f('ck_session_adaptations_source_valid')),
    sa.PrimaryKeyConstraint('id', name=op.f('pk_session_adaptations'))
    )
    op.create_index(op.f('ix_session_adaptations_session_id'), 'session_adaptations', ['session_id'], unique=False)
    op.create_index('uq_session_adaptations_active_ref', 'session_adaptations', ['session_id', 'ingredient_ref'], unique=True, postgresql_where=sa.text('reverted_at IS NULL'))
    op.create_table('session_notes',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('session_id', sa.UUID(), nullable=False),
    sa.Column('text', sa.Text(), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['session_id'], ['cooking_sessions.id'], name=op.f('fk_session_notes_session_id_cooking_sessions'), ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id', name=op.f('pk_session_notes'))
    )
    op.create_index(op.f('ix_session_notes_session_id'), 'session_notes', ['session_id'], unique=False)
    op.create_table('usage_events',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('user_id', sa.UUID(), nullable=False),
    sa.Column('kind', sa.String(length=32), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], name=op.f('fk_usage_events_user_id_users'), ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id', name=op.f('pk_usage_events'))
    )
    op.create_index('ix_usage_events_user_kind_created', 'usage_events', ['user_id', 'kind', 'created_at'], unique=False)
    op.add_column('cooking_sessions', sa.Column('outcome_json', postgresql.JSONB(astext_type=sa.Text()), nullable=True))
    op.add_column('session_events', sa.Column('request_hash', sa.String(length=64), nullable=True))
    op.add_column('session_events', sa.Column('response_json', postgresql.JSONB(astext_type=sa.Text()), nullable=True))


def downgrade() -> None:
    op.drop_column('session_events', 'response_json')
    op.drop_column('session_events', 'request_hash')
    op.drop_column('cooking_sessions', 'outcome_json')
    op.drop_index('ix_usage_events_user_kind_created', table_name='usage_events')
    op.drop_table('usage_events')
    op.drop_index(op.f('ix_session_notes_session_id'), table_name='session_notes')
    op.drop_table('session_notes')
    op.drop_index('uq_session_adaptations_active_ref', table_name='session_adaptations', postgresql_where=sa.text('reverted_at IS NULL'))
    op.drop_index(op.f('ix_session_adaptations_session_id'), table_name='session_adaptations')
    op.drop_table('session_adaptations')
    op.drop_index(op.f('ix_substitution_suggestions_owner_user_id'), table_name='substitution_suggestions')
    op.drop_index('ix_substitution_suggestions_owner_created', table_name='substitution_suggestions')
    op.drop_index(op.f('ix_substitution_suggestions_expires_at'), table_name='substitution_suggestions')
    op.drop_table('substitution_suggestions')
    op.drop_index(op.f('ix_recipe_variations_recipe_id'), table_name='recipe_variations')
    op.drop_index(op.f('ix_recipe_variations_owner_user_id'), table_name='recipe_variations')
    op.drop_table('recipe_variations')
    op.drop_table('user_preferences')
    op.drop_table('substitution_rules')
