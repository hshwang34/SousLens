"""Dated Gemini price table (USD per 1M tokens, paid tier, Standard).

Source: https://ai.google.dev/gemini-api/docs/pricing, verified 2026-10-28. Thinking tokens are
billed as output ("Output price (including thinking tokens)"). A row applies from its
``effective_from`` (UTC) until the next row for the same model.

Unknown models fail closed: they are priced at :data:`WORST_CASE`, which is above every row
here, so a typo in a model setting can only make the cost guard stricter, never looser.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal

PER_MILLION = Decimal(1_000_000)


@dataclass(frozen=True)
class Price:
    input_per_m: Decimal
    output_per_m: Decimal


@dataclass(frozen=True)
class PriceRow:
    model: str
    effective_from: datetime
    price: Price


def _d(value: str) -> Decimal:
    return Decimal(value)


_EPOCH = datetime(2026, 1, 1, tzinfo=UTC)

PRICE_TABLE: tuple[PriceRow, ...] = (
    # gemini-3.8-flash: $0.75 / $3.75 through 2026-12-31, then doubles on 2027-01-01.
    PriceRow("gemini-3.8-flash", _EPOCH, Price(_d("0.75"), _d("3.75"))),
    PriceRow("gemini-3.8-flash", datetime(2027, 1, 1, tzinfo=UTC), Price(_d("1.50"), _d("7.50"))),
    # gemini-3.5-flash-lite: $0.30 (text / image / video / audio) / $2.50; no change announced.
    PriceRow("gemini-3.5-flash-lite", _EPOCH, Price(_d("0.30"), _d("2.50"))),
)

# Above every row in the table (and above Gemini 4 Argon's Dec-2026 $4 / $20), so an unknown or
# mistyped model id is charged as the most expensive thing we could plausibly be calling.
WORST_CASE = Price(_d("5.00"), _d("25.00"))


def price_for(model: str, at: datetime) -> Price:
    rows = [r for r in PRICE_TABLE if r.model == model and r.effective_from <= at]
    if not rows:
        return WORST_CASE
    return max(rows, key=lambda r: r.effective_from).price


def is_known(model: str) -> bool:
    return any(r.model == model for r in PRICE_TABLE)


def cost_usd(model: str, at: datetime, *, input_tokens: int, output_tokens: int) -> Decimal:
    """``output_tokens`` must already include thinking tokens (they bill as output)."""
    price = price_for(model, at)
    return (
        Decimal(max(input_tokens, 0)) * price.input_per_m
        + Decimal(max(output_tokens, 0)) * price.output_per_m
    ) / PER_MILLION
