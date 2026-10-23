"""Pure publish rules and PATCH merge semantics (no DB)."""

from __future__ import annotations

import pytest

from app.domains.recipes.draft_schemas import DraftContent, DraftPatch, validate_https_url
from app.domains.recipes.drafts import apply_patch, normalise, slugify, validate


def _content(**kw: object) -> DraftContent:
    base: dict[str, object] = {
        "title": "Soup",
        "servings": 2,
        "ingredients": [{"id": "a", "name": "water"}],
        "steps": [{"id": "s", "order": 0, "instruction": "Boil.", "ingredient_refs": ["a"]}],
    }
    base.update(kw)
    return DraftContent.model_validate(base)


def test_valid_content_is_publishable() -> None:
    assert validate(_content()).publishable is True


def test_each_rule_fires_alone() -> None:
    assert [p.field for p in validate(_content(title=" ")).problems] == ["title"]
    assert [p.field for p in validate(_content(title="x" * 121)).problems] == ["title"]
    assert validate(_content(title="x" * 120)).publishable is True
    assert [p.field for p in validate(_content(servings=None)).problems] == ["servings"]
    assert [p.field for p in validate(_content(servings=0)).problems] == ["servings"]
    bad_refs = _content(
        steps=[{"id": "s", "order": 0, "instruction": "x", "ingredient_refs": ["zz"]}]
    )
    assert [p.field for p in validate(bad_refs).problems] == ["steps[0].ingredient_refs"]
    unordered = _content(steps=[{"id": "s", "order": 3, "instruction": "x"}])
    assert [p.field for p in validate(unordered).problems] == ["steps[0].order"]


def test_normalise_rewrites_order_and_materialises_defaults() -> None:
    content = _content(
        steps=[
            {"id": "b", "order": 9, "instruction": "two"},
            {"id": "a", "order": 1, "instruction": "one"},
        ]
    )
    stored = normalise(content)
    assert [(s["id"], s["order"]) for s in stored["steps"]] == [("b", 0), ("a", 1)]
    assert stored["steps"][1]["evidence_origin"] == "creator_authored"
    assert stored["ingredients"][0]["optional"] is False
    assert set(stored) == {
        "title", "summary", "tags", "cover_image_url", "servings", "prep_minutes",
        "cook_minutes", "ingredients", "steps", "creator_notes", "dietary_warnings",
    }  # fmt: skip


def test_apply_patch_only_touches_provided_fields() -> None:
    content = _content(summary="keep me")
    patched = apply_patch(content, DraftPatch.model_validate({"title": "New"}))
    assert patched.title == "New" and patched.summary == "keep me"
    assert len(patched.ingredients) == 1
    cleared = apply_patch(content, DraftPatch.model_validate({"summary": None, "steps": []}))
    assert cleared.summary is None and cleared.steps == [] and cleared.title == "Soup"
    echoed = apply_patch(content, DraftPatch.model_validate({"id": "x", "status": "published"}))
    assert echoed == content


def test_slugify() -> None:
    assert slugify("  Crispy Rice!! (v1) ") == "crispy-rice-v1"
    assert slugify("@@@") == "recipe"
    assert len(slugify("word " * 100)) <= 140


@pytest.mark.parametrize(
    "value",
    [
        "https://a.example/x.jpg",
        "HTTPS://A.EXAMPLE/x",
        "https://a.example:8443/x?y=1#z",
        "https://[2001:db8::1]/x.jpg",
        None,
    ],
)
def test_https_url_accepts_and_stores_as_given(value: str | None) -> None:
    assert validate_https_url(value) == value


@pytest.mark.parametrize(
    "value",
    [
        "http://a.example/x.jpg",
        "javascript:alert(1)",
        "//a.example/x.jpg",
        "https:///x.jpg",
        "https://user@a.example/x.jpg",
        "https://a.example/" + "x" * 2048,
        "  https://a.example  ",
        "https://a.example/a b",
        "https://a.example/\tx",
        "https://a.example/\nx",
        "https://a.example/\x00",
        "https://a.example/\x7f",
        "https://a.example\\@evil.example/",
        "https:\\\\evil.example/",
        "https://a.example:99999/x",
        "https://a.example:abc/x",
        "https://[::1/x",
    ],
)
def test_https_url_rejects(value: str) -> None:
    with pytest.raises(ValueError):
        validate_https_url(value)
