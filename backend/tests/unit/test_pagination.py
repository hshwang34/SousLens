from __future__ import annotations

import uuid
from datetime import UTC, datetime

import pytest

from app.core.errors import ValidationError
from app.domains.recipes.pagination import FeedCursor


def test_cursor_round_trip() -> None:
    cursor = FeedCursor(
        published_at=datetime(2026, 10, 15, 12, 30, 0, 123456, tzinfo=UTC),
        recipe_id=uuid.uuid4(),
    )
    token = cursor.encode()
    assert "=" not in token
    assert FeedCursor.decode(token) == cursor


@pytest.mark.parametrize("bad", ["", "!!!", "eyJ4IjoxfQ", "bm90IGpzb24"])
def test_invalid_cursor_is_validation_error(bad: str) -> None:
    with pytest.raises(ValidationError):
        FeedCursor.decode(bad)
