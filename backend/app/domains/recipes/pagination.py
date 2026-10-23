"""Opaque keyset cursor over ``(published_at, id)`` for the public feed."""

from __future__ import annotations

import base64
import binascii
import json
import uuid
from dataclasses import dataclass
from datetime import datetime

from app.core.errors import ValidationError


@dataclass(frozen=True, slots=True)
class FeedCursor:
    published_at: datetime
    recipe_id: uuid.UUID

    def encode(self) -> str:
        raw = json.dumps({"p": self.published_at.isoformat(), "id": str(self.recipe_id)})
        return base64.urlsafe_b64encode(raw.encode()).decode().rstrip("=")

    @classmethod
    def decode(cls, token: str) -> FeedCursor:
        try:
            padded = token + "=" * (-len(token) % 4)
            data = json.loads(base64.urlsafe_b64decode(padded.encode()))
            published_at = datetime.fromisoformat(data["p"])
            if published_at.tzinfo is None:
                raise ValueError("cursor timestamp must be timezone-aware")
            return cls(published_at=published_at, recipe_id=uuid.UUID(data["id"]))
        except (binascii.Error, ValueError, KeyError, TypeError, UnicodeDecodeError) as exc:
            raise ValidationError("Invalid cursor") from exc
