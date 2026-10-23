"""Unit tables (PRD §12.2, brief 004 contract). Pure.

Pantry units are exactly the contract list. Conversion happens only inside a family (count,
mass, volume); there is deliberately no mass↔volume conversion, because that needs a density
the dictionary does not know. Recipe units outside the list ("clove", "sheet", "pinch") are kept
as-is and are only comparable with the identical unit.
"""

from __future__ import annotations

from typing import Literal

PantryUnit = Literal["count", "g", "kg", "oz", "lb", "ml", "l", "tsp", "tbsp", "cup", "fl_oz"]
PANTRY_UNITS: tuple[str, ...] = (
    "count",
    "g",
    "kg",
    "oz",
    "lb",
    "ml",
    "l",
    "tsp",
    "tbsp",
    "cup",
    "fl_oz",
)

Family = Literal["count", "mass", "volume"]

# Factor to the family's base unit (count: 1, mass: gram, volume: millilitre). US customary.
_FACTORS: dict[str, tuple[Family, float]] = {
    "count": ("count", 1.0),
    "g": ("mass", 1.0),
    "kg": ("mass", 1000.0),
    "oz": ("mass", 28.349523125),
    "lb": ("mass", 453.59237),
    "ml": ("volume", 1.0),
    "l": ("volume", 1000.0),
    "tsp": ("volume", 4.92892159375),
    "tbsp": ("volume", 14.78676478125),
    "cup": ("volume", 236.5882365),
    "fl_oz": ("volume", 29.5735295625),
}

_SYNONYMS: dict[str, str] = {
    "": "count",
    "count": "count",
    "ct": "count",
    "each": "count",
    "ea": "count",
    "piece": "count",
    "pieces": "count",
    "pc": "count",
    "pcs": "count",
    "whole": "count",
    "unit": "count",
    "units": "count",
    "g": "g",
    "gram": "g",
    "grams": "g",
    "gr": "g",
    "kg": "kg",
    "kilo": "kg",
    "kilos": "kg",
    "kilogram": "kg",
    "kilograms": "kg",
    "oz": "oz",
    "ounce": "oz",
    "ounces": "oz",
    "lb": "lb",
    "lbs": "lb",
    "pound": "lb",
    "pounds": "lb",
    "ml": "ml",
    "milliliter": "ml",
    "milliliters": "ml",
    "millilitre": "ml",
    "millilitres": "ml",
    "l": "l",
    "liter": "l",
    "liters": "l",
    "litre": "l",
    "litres": "l",
    "tsp": "tsp",
    "teaspoon": "tsp",
    "teaspoons": "tsp",
    "tbsp": "tbsp",
    "tbs": "tbsp",
    "tablespoon": "tbsp",
    "tablespoons": "tbsp",
    "cup": "cup",
    "cups": "cup",
    "c": "cup",
    "fl_oz": "fl_oz",
    "fl oz": "fl_oz",
    "fl. oz": "fl_oz",
    "fluid ounce": "fl_oz",
    "fluid ounces": "fl_oz",
}

_DISPLAY: dict[str, tuple[str, str]] = {
    "g": ("g", "g"),
    "kg": ("kg", "kg"),
    "oz": ("oz", "oz"),
    "lb": ("lb", "lb"),
    "ml": ("ml", "ml"),
    "l": ("l", "l"),
    "tsp": ("tsp", "tsp"),
    "tbsp": ("tbsp", "tbsp"),
    "cup": ("cup", "cups"),
    "fl_oz": ("fl oz", "fl oz"),
}


def canonical_unit(raw: str | None) -> str:
    """Contract unit for a known spelling, else the cleaned raw unit (e.g. "clove").

    ``None``/empty means "count" (a bare number: "3 eggs")."""
    value = (raw or "").strip().casefold().rstrip(".")
    return _SYNONYMS.get(value, value)


def pantry_unit(raw: str | None) -> str | None:
    """A unit acceptable on a pantry item, or ``None`` when it is not in the contract list."""
    unit = canonical_unit(raw)
    return unit if unit in _FACTORS else None


def family(unit: str) -> Family | None:
    hit = _FACTORS.get(unit)
    return hit[0] if hit else None


def convert(quantity: float, from_unit: str, to_unit: str) -> float | None:
    """Within-family conversion, else ``None`` (never mass↔volume)."""
    if from_unit == to_unit:
        return quantity
    a, b = _FACTORS.get(from_unit), _FACTORS.get(to_unit)
    if a is None or b is None or a[0] != b[0]:
        return None
    return quantity * a[1] / b[1]


def format_quantity(quantity: float) -> str:
    rounded = round(quantity, 2)
    if rounded == int(rounded):
        return str(int(rounded))
    return f"{rounded:.2f}".rstrip("0").rstrip(".")


def display_unit(unit: str, quantity: float) -> str:
    singular, plural = _DISPLAY.get(unit, (unit, unit if unit.endswith("s") else unit + "s"))
    return singular if quantity <= 1 else plural
