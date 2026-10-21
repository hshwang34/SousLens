"""Seed fixtures are validated strictly: unknown keys must be rejected (write side)."""

import json
from pathlib import Path

import pytest
from pydantic import ValidationError

from app.scripts.seed import SeedRecipe

FIXTURE = Path(__file__).resolve().parents[3] / "fixtures" / "seeded_recipes"


def _load() -> dict:
    path = next(FIXTURE.glob("*.json"))
    return json.loads(path.read_text())


def test_seed_fixture_validates() -> None:
    SeedRecipe.model_validate(_load())


def test_seed_rejects_unknown_top_level_key() -> None:
    data = _load()
    data["bogus"] = 1
    with pytest.raises(ValidationError):
        SeedRecipe.model_validate(data)


def test_seed_rejects_unknown_ingredient_key() -> None:
    data = _load()
    data["ingredients"][0]["calories"] = 120
    with pytest.raises(ValidationError):
        SeedRecipe.model_validate(data)


def test_seed_rejects_unknown_step_key() -> None:
    data = _load()
    data["steps"][0]["auto_advance"] = True
    with pytest.raises(ValidationError):
        SeedRecipe.model_validate(data)
