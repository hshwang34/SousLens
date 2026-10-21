"""SEC-01: owned rows fetched by a different user are a 404, never a 403 with metadata."""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import NotFound
from app.db.models import DraftStatus, PantryItem, PantrySource, RecipeDraft
from app.domains.ownership import get_owned_or_404
from app.domains.users import service as users_service


async def test_owner_sees_row_and_other_user_gets_404(db_session: AsyncSession) -> None:
    alice = await users_service.get_or_create_by_email(
        db_session, email="alice@example.com", display_name=None, auth_provider="dev"
    )
    bob = await users_service.get_or_create_by_email(
        db_session, email="bob@example.com", display_name=None, auth_provider="dev"
    )
    draft = RecipeDraft(
        owner_user_id=alice.id,
        structured_draft_json={"title": "secret"},
        status=DraftStatus.EDITING,
    )
    pantry = PantryItem(
        owner_user_id=alice.id,
        raw_label="gochujang",
        normalized_name="gochujang",
        source=PantrySource.MANUAL,
    )
    db_session.add_all([draft, pantry])
    await db_session.flush()

    assert (await get_owned_or_404(db_session, RecipeDraft, draft.id, alice.id)) is draft
    assert (await get_owned_or_404(db_session, PantryItem, pantry.id, alice.id)) is pantry

    with pytest.raises(NotFound) as exc:
        await get_owned_or_404(db_session, RecipeDraft, draft.id, bob.id, label="Draft")
    assert exc.value.status_code == 404
    assert "secret" not in exc.value.message

    with pytest.raises(NotFound):
        await get_owned_or_404(db_session, PantryItem, pantry.id, bob.id)


async def test_unknown_id_is_404_for_everyone(db_session: AsyncSession) -> None:
    alice = await users_service.get_or_create_by_email(
        db_session, email="alice@example.com", display_name=None, auth_provider="dev"
    )
    with pytest.raises(NotFound):
        await get_owned_or_404(db_session, RecipeDraft, uuid.uuid4(), alice.id)
