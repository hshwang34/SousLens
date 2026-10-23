"""Candidate post-processing, confidence bins and upload sniffing (PRD §8.3, PRIV-01)."""

from __future__ import annotations

import uuid
from pathlib import Path

import pytest

from app.ai.providers.base import PantryCandidate, PantryObservation
from app.core.errors import PayloadTooLarge, UnsupportedMediaType, ValidationError
from app.domains.matching.dictionary import load_dictionary_file
from app.domains.pantry.observations import confidence_bin, finalize_candidate, unknowns_for
from app.domains.pantry.upload import MAX_IMAGE_BYTES, parse_multipart, sniff_image

FIXTURES_DIR = Path(__file__).resolve().parents[2].parent / "fixtures"
D = load_dictionary_file(FIXTURES_DIR)


def cand(**kw: object) -> PantryCandidate:
    base: dict[str, object] = {
        "raw_label": "x",
        "canonical_name": "x",
        "confidence": 0.9,
        "evidence": "e",
    }
    base.update(kw)
    return PantryCandidate.model_validate(base)


@pytest.mark.parametrize(
    ("c", "b"),
    [(0.99, "high"), (0.86, "high"), (0.85, "medium"), (0.6, "medium"), (0.59, "unknown")],
)
def test_confidence_bins(c: float, b: str) -> None:
    assert confidence_bin(c) == b


def test_canonical_goes_through_the_dictionary() -> None:
    out = finalize_candidate(
        cand(raw_label="green onions", canonical_name="green onions"), "transcript", D, {}
    )
    assert out.canonical_name == "scallion"


def test_bare_number_is_count_and_packaging_unit_is_unknown_amount() -> None:
    assert finalize_candidate(cand(quantity=2), "transcript", D, {}).unit == "count"
    out = finalize_candidate(cand(quantity=2, unit="can"), "transcript", D, {})
    assert out.quantity is None and out.unit is None


def test_photo_quantity_is_always_an_estimate_transcript_never() -> None:
    assert finalize_candidate(cand(quantity=3), "photo", D, {}).quantity_is_estimate is True
    assert finalize_candidate(cand(quantity=3), "transcript", D, {}).quantity_is_estimate is False
    assert finalize_candidate(cand(), "photo", D, {}).quantity_is_estimate is False


def test_unknown_bin_and_unnamed_default_to_ignore() -> None:
    assert finalize_candidate(cand(confidence=0.4, action="add"), "photo", D, {}).action == "ignore"
    assert finalize_candidate(cand(canonical_name=None), "photo", D, {}).action == "ignore"
    assert finalize_candidate(cand(action="update"), "photo", D, {}).action == "add"


def test_duplicate_of_is_prefilled_from_pantry_keys() -> None:
    item_id = uuid.uuid4()
    out = finalize_candidate(
        cand(raw_label="Spring onions", canonical_name="spring onion"),
        "transcript",
        D,
        {"scallion": item_id},
    )
    assert out.duplicate_of == item_id


def test_unknowns_fall_back_to_unnamed_candidates() -> None:
    c = finalize_candidate(
        cand(raw_label="unlabeled jar", canonical_name=None, evidence="no label"), "photo", D, {}
    )
    obs = PantryObservation(mode="photo", candidates=[])
    assert unknowns_for(obs, [c]) == ["unlabeled jar: no label"]
    obs2 = PantryObservation(mode="photo", candidates=[], unknowns=["the jar"])
    assert unknowns_for(obs2, [c]) == ["the jar"]


@pytest.mark.parametrize(
    ("data", "mime"),
    [
        (b"\xff\xd8\xff\xe0" + b"0" * 10, "image/jpeg"),
        (b"\x89PNG\r\n\x1a\n" + b"0" * 10, "image/png"),
        (b"\x00\x00\x00\x18ftypheic" + b"0" * 10, "image/heic"),
        (b"\x00\x00\x00\x18ftypmif1" + b"0" * 10, "image/heic"),
    ],
)
def test_sniff_accepts_jpeg_png_heic(data: bytes, mime: str) -> None:
    assert sniff_image(data) == mime


@pytest.mark.parametrize(
    "data", [b"GIF89a....", b"%PDF-1.7", b"\x00\x00\x00\x18ftypmp42xxxx", b"", b"<svg/>"]
)
def test_sniff_rejects_everything_else(data: bytes) -> None:
    with pytest.raises(UnsupportedMediaType):
        sniff_image(data)


def _multipart(parts: list[tuple[str, str | None, bytes]], boundary: str = "XyZ") -> bytes:
    out = b""
    for name, filename, data in parts:
        disp = f'form-data; name="{name}"' + (f'; filename="{filename}"' if filename else "")
        out += f"--{boundary}\r\nContent-Disposition: {disp}\r\n\r\n".encode() + data + b"\r\n"
    return out + f"--{boundary}--\r\n".encode()


def test_parse_multipart_in_memory() -> None:
    body = _multipart([("mode", None, b"photo"), ("image", "pantry.jpg", b"\xff\xd8\xffabc")])
    parts = parse_multipart(body, "multipart/form-data; boundary=XyZ")
    assert bytes(parts["mode"].data) == b"photo"
    assert parts["image"].filename == "pantry.jpg"
    assert bytes(parts["image"].data) == b"\xff\xd8\xffabc"


def test_parse_multipart_caps_image_and_fields() -> None:
    big = _multipart([("image", "a.jpg", b"\xff" * (MAX_IMAGE_BYTES + 1))])
    with pytest.raises(PayloadTooLarge):
        parse_multipart(big, "multipart/form-data; boundary=XyZ")
    long_field = _multipart([("mode", None, b"x" * 5000)])
    with pytest.raises(ValidationError):
        parse_multipart(long_field, "multipart/form-data; boundary=XyZ")
    with pytest.raises(ValidationError):
        parse_multipart(b"junk", "multipart/form-data")
