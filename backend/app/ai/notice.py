"""The flag every AI-backed response carries when its answer is not from the live model
(brief 007): a budget cap was reached, so the labelled demo (mock) path answered instead.

The field is omitted entirely when absent, so ``AI_PROVIDER=mock`` responses stay byte-identical
to Slice 3.
"""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field

RESTING_MESSAGE = "AI is resting — demo answers for now"
DenialReason = Literal["user_daily_cap", "monthly_cap"]


class AINotice(BaseModel):
    code: Literal["AI_RESTING"] = "AI_RESTING"
    message: str = RESTING_MESSAGE
    reason: DenialReason
    demo: Literal[True] = True


def _absent(value: Any) -> bool:
    return value is None


def notice_field() -> Any:
    """``ai_notice: AINotice | None = notice_field()`` — serialised only when set."""
    return Field(default=None, exclude_if=_absent)
