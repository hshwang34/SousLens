"""Vetted seed substitution rules (``fixtures/substitution_rules.json``, PRD §12.3).

``make seed`` upserts them into ``substitution_rules`` keyed on the dictionary canonical name;
the API reads them back from the database per request (a few dozen rows).
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import SubstitutionRule

RULES_FILE = "substitution_rules.json"

ContractKind = Literal["close_equivalent", "flavor_adaptation", "structural_substitution"]
ConfidenceLabel = Literal["high", "medium", "low"]


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class RuleSuggestion(_Strict):
    candidate: str = Field(min_length=1, max_length=200)
    kind: ContractKind
    ratio_or_amount: str = Field(min_length=1, max_length=200)
    rationale: str = Field(min_length=1, max_length=300)
    impact_flavor: str = Field(min_length=1, max_length=200)
    impact_texture: str = Field(min_length=1, max_length=200)
    confidence: ConfidenceLabel
    risks: list[str] = Field(default_factory=list)


class SeedRule(_Strict):
    target: str = Field(min_length=1, max_length=120)
    suggestions: list[RuleSuggestion] = Field(default_factory=list, max_length=3)
    exhaustive: bool = False
    never: list[str] = Field(default_factory=list)
    no_swap_reason: str | None = None
    note: str | None = None

    @model_validator(mode="after")
    def _swap_xor_no_swap(self) -> SeedRule:
        if bool(self.suggestions) == bool(self.no_swap_reason):
            raise ValueError(f"{self.target!r}: give suggestions or a no_swap_reason, not both")
        return self


class RulesFile(_Strict):
    version: int
    note: str | None = None
    rules: list[SeedRule]

    @model_validator(mode="after")
    def _unique_targets(self) -> RulesFile:
        seen: set[str] = set()
        for rule in self.rules:
            if rule.target in seen:
                raise ValueError(f"duplicate rule target {rule.target!r}")
            seen.add(rule.target)
        return self


def read_rules_file(fixtures_dir: Path) -> RulesFile:
    path = Path(fixtures_dir) / RULES_FILE
    return RulesFile.model_validate(json.loads(path.read_text(encoding="utf-8")))


async def load_rules(session: AsyncSession) -> dict[str, SeedRule]:
    """Rules by target canonical name. A row that no longer validates is skipped, never 500."""
    rows = (await session.execute(select(SubstitutionRule))).scalars().all()
    rules: dict[str, SeedRule] = {}
    for row in rows:
        try:
            rules[row.target] = SeedRule.model_validate(row.rule_json)
        except ValueError:
            continue
    return rules
