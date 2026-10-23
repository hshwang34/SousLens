"""PRD §17.3 voice-transcript evaluation subset: the mock parser over 15 fixture transcripts.

Scores the *raw* parser output after the server's deterministic post-processing (never a
user-corrected pantry), as §17.3 requires. A candidate is a true positive only when canonical
name, quantity and unit all match. The parser is deterministic, so the bar is 0.8 on both.
Note: these transcripts were written alongside the parser; the score shows the parser handles
the listed phenomena, not how it would do on real speech-to-text output.
"""

from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

import pytest

from app.ai.providers.mock import parse_transcript
from app.domains.matching.dictionary import load_dictionary_file
from app.domains.pantry.observations import finalize_candidate

FIXTURES_DIR = Path(__file__).resolve().parents[2].parent / "fixtures"
TRANSCRIPTS = json.loads((FIXTURES_DIR / "pantry_transcripts.json").read_text())["transcripts"]

Key = tuple[str | None, float | None, str | None]


def _predict(transcript: str) -> list[Key]:
    d = load_dictionary_file(FIXTURES_DIR)
    return [
        (c.canonical_name, c.quantity, c.unit)
        for c in (finalize_candidate(p, "transcript", d, {}) for p in parse_transcript(transcript))
    ]


def _expected(case: dict) -> list[Key]:
    return [(e["canonical_name"], e["quantity"], e["unit"]) for e in case["expected"]]


def test_fixture_has_15_transcripts_covering_the_prd_phenomena() -> None:
    assert len(TRANSCRIPTS) == 15
    tags = {t for case in TRANSCRIPTS for t in case["tags"]}
    assert {"synonyms", "correction", "noise", "units", "number_words", "digits"} <= tags


def test_precision_and_recall_at_least_0_8(capsys: pytest.CaptureFixture[str]) -> None:
    tp = fp = fn = 0
    for case in TRANSCRIPTS:
        predicted, expected = Counter(_predict(case["transcript"])), Counter(_expected(case))
        hit = sum((predicted & expected).values())
        tp += hit
        fp += sum(predicted.values()) - hit
        fn += sum(expected.values()) - hit
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    with capsys.disabled():
        print(
            f"\n[pantry transcript eval] n=15 tp={tp} fp={fp} fn={fn} "
            f"precision={precision:.3f} recall={recall:.3f}"
        )
    assert precision >= 0.8
    assert recall >= 0.8


@pytest.mark.parametrize("case", TRANSCRIPTS, ids=[c["id"] for c in TRANSCRIPTS])
def test_each_transcript(case: dict) -> None:
    assert _predict(case["transcript"]) == _expected(case)


def test_live_smoke_transcript_yields_gochujang_3_tbsp() -> None:
    got = _predict("chicken thighs, two onions, 3 tbsp gochujang and honey")
    assert got == [
        ("chicken thigh", None, None),
        ("onion", 2, "count"),
        ("gochujang", 3, "tbsp"),
        ("honey", None, None),
    ]
