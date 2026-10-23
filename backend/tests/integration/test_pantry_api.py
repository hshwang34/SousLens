"""Pantry CRUD, ownership, hygiene and duplicate resolution (PAN-01, PAN-04, PAN-05)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

import pytest
from httpx import AsyncClient

from tests.conftest import bearer

pytestmark = pytest.mark.usefixtures("ingredients")

ITEM_KEYS = {
    "id",
    "raw_label",
    "normalized_name",
    "ingredient_id",
    "quantity",
    "unit",
    "quantity_is_estimate",
    "storage_location",
    "note",
    "source",
    "confidence",
    "last_confirmed_at",
    "created_at",
    "updated_at",
}


def new(label: str, **kw: object) -> dict[str, object]:
    item: dict[str, object] = {
        "raw_label": label,
        "source": "manual",
        "quantity_is_estimate": False,
    }
    item.update(kw)
    return item


async def add(client: AsyncClient, h: dict[str, str], *items: dict, obs: str | None = None):
    return await client.post(
        "/v1/pantry", json={"items": list(items), "observation_id": obs}, headers=h
    )


async def test_requires_auth(client: AsyncClient) -> None:
    assert (await client.get("/v1/pantry")).status_code == 401
    assert (await client.post("/v1/pantry", json={"items": []})).status_code == 401


async def test_create_list_shape_and_normalisation(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    before = datetime.now(UTC)
    r = await add(
        client,
        h,
        new(
            "  Green Onions ",
            quantity=2,
            unit="count",
            storage_location="fridge",
            note="for kimchi",
        ),
        new("Gochujang", source="voice", confidence=0.91),
        new("Mystery sauce", confidence=0.5),
    )
    assert r.status_code == 201, r.text
    items = r.json()["items"]
    assert [set(i) for i in items] == [ITEM_KEYS] * 3
    scallion, gochujang, mystery = items
    assert scallion["raw_label"] == "Green Onions"
    assert scallion["normalized_name"] == "scallion"
    assert scallion["ingredient_id"] is not None
    assert scallion["quantity"] == 2.0 and scallion["unit"] == "count"
    assert scallion["storage_location"] == "fridge" and scallion["note"] == "for kimchi"
    assert scallion["confidence"] is None  # manual → null
    assert datetime.fromisoformat(scallion["last_confirmed_at"]) >= before
    assert gochujang["source"] == "voice" and gochujang["confidence"] == 0.91
    assert mystery["ingredient_id"] is None and mystery["normalized_name"] == "mystery sauce"

    listed = (await client.get("/v1/pantry", headers=h)).json()["items"]
    assert [i["normalized_name"] for i in listed] == ["gochujang", "mystery sauce", "scallion"]


@pytest.mark.parametrize(
    "item",
    [
        new(""),
        new("   "),
        new("a‮b"),
        new("two\nlines"),
        new("x" * 201),
        new("ok", note="n" * 501),
        new("ok", unit="bunch", quantity=1),
        new("ok", unit="tablespoon", quantity=1),
        new("ok", quantity=-1),
        new("ok", storage_location="garage"),
        new("ok", source="telepathy"),
        new("ok", confidence=1.5),
        new("ok", surprise=True),
        new("ok", resolution={"merge_into": "nope"}),
        new("ok", resolution={"keep_both": False}),
        new("!!!"),
    ],
)
async def test_validation(client: AsyncClient, item: dict) -> None:
    h = await bearer(client, "a@example.com")
    r = await add(client, h, item)
    assert r.status_code == 422, r.text
    assert r.json()["error"]["code"] == "VALIDATION_ERROR"
    assert (await client.get("/v1/pantry", headers=h)).json()["items"] == []


async def test_note_may_be_multiline_and_is_trimmed(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    r = await add(client, h, new("honey", note="  top shelf\nbehind the rice  "))
    assert r.json()["items"][0]["note"] == "top shelf\nbehind the rice"


async def test_quantity_is_estimate_only_survives_on_photo_quantities(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    r = await add(
        client,
        h,
        new("onion", source="photo", quantity=3, quantity_is_estimate=True, confidence=0.8),
        new("garlic", source="photo", quantity_is_estimate=True, confidence=0.8),
        new("lemon", quantity=2, quantity_is_estimate=True),
    )
    assert [i["quantity_is_estimate"] for i in r.json()["items"]] == [True, False, False]


async def test_empty_and_oversized_batches_are_rejected(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    assert (await add(client, h)).status_code == 422
    many = [new(f"thing {n}") for n in range(101)]
    assert (await add(client, h, *many)).status_code == 422


# --- duplicates (PAN-04) ------------------------------------------------------------------


async def test_duplicate_without_resolution_is_409_and_nothing_written(
    client: AsyncClient,
) -> None:
    h = await bearer(client, "a@example.com")
    first = (await add(client, h, new("scallions", quantity=2))).json()["items"][0]
    r = await add(client, h, new("honey"), new("spring onion", source="voice", confidence=0.9))
    assert r.status_code == 409
    err = r.json()["error"]
    assert err["code"] == "DUPLICATE_PANTRY_ITEM"
    conflicts = err["details"]["conflicts"]
    assert len(conflicts) == 1
    assert conflicts[0]["index"] == 1
    assert conflicts[0]["existing"]["id"] == first["id"]
    assert set(conflicts[0]["existing"]) == ITEM_KEYS
    # honey (index 0) was not written either: the whole request is rejected.
    names = [
        i["normalized_name"] for i in (await client.get("/v1/pantry", headers=h)).json()["items"]
    ]
    assert names == ["scallion"]


async def test_gochugaru_is_not_a_duplicate_of_gochujang(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    await add(client, h, new("gochujang"))
    assert (await add(client, h, new("gochugaru"))).status_code == 201
    assert (await add(client, h, new("cooked rice"))).status_code == 201
    assert (await add(client, h, new("rice"))).status_code == 201


async def test_merge_into_updates_existing(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    first = (
        await add(client, h, new("eggs", quantity=2, storage_location="fridge", note="brown"))
    ).json()["items"][0]
    r = await add(
        client,
        h,
        new(
            "egg",
            source="voice",
            confidence=0.9,
            quantity=12,
            unit="count",
            resolution={"merge_into": first["id"]},
        ),
    )
    assert r.status_code == 201, r.text
    merged = r.json()["items"][0]
    assert merged["id"] == first["id"]
    assert merged["quantity"] == 12.0
    assert merged["source"] == "voice" and merged["confidence"] == 0.9
    assert merged["storage_location"] == "fridge" and merged["note"] == "brown"  # kept
    assert merged["raw_label"] == "eggs"
    assert merged["last_confirmed_at"] > first["last_confirmed_at"]
    assert len((await client.get("/v1/pantry", headers=h)).json()["items"]) == 1


async def test_merge_without_quantity_keeps_existing_amount(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    first = (await add(client, h, new("honey", quantity=1, unit="cup"))).json()["items"][0]
    merged = (await add(client, h, new("Honey", resolution={"merge_into": first["id"]}))).json()[
        "items"
    ][0]
    assert merged["quantity"] == 1.0 and merged["unit"] == "cup"


async def test_keep_both_creates_a_second_item(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    await add(client, h, new("eggs", quantity=2))
    r = await add(client, h, new("eggs", quantity=6, resolution={"keep_both": True}))
    assert r.status_code == 201
    assert len((await client.get("/v1/pantry", headers=h)).json()["items"]) == 2


async def test_merge_into_must_target_a_same_name_item_of_mine(client: AsyncClient) -> None:
    a = await bearer(client, "a@example.com")
    b = await bearer(client, "b@example.com")
    mine = (await add(client, a, new("honey"))).json()["items"][0]
    garlic = (await add(client, a, new("garlic"))).json()["items"][0]
    theirs = (await add(client, b, new("honey"))).json()["items"][0]
    for target in (theirs["id"], garlic["id"], str(uuid.uuid4())):
        r = await add(client, a, new("honey", resolution={"merge_into": target}))
        assert r.status_code == 422, target
    assert (
        await add(client, a, new("honey", resolution={"merge_into": mine["id"]}))
    ).status_code == 201


async def test_same_ingredient_twice_in_one_request(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    r = await add(client, h, new("onion"), new("onions"))
    assert r.status_code == 422
    assert r.json()["error"]["fields"] == ["items.1.raw_label"]
    ok = await add(client, h, new("onion"), new("onions", resolution={"keep_both": True}))
    assert ok.status_code == 201


async def test_duplicates_are_per_user(client: AsyncClient) -> None:
    a = await bearer(client, "a@example.com")
    b = await bearer(client, "b@example.com")
    await add(client, a, new("honey"))
    assert (await add(client, b, new("honey"))).status_code == 201


# --- PATCH / confirm / DELETE --------------------------------------------------------------


async def test_patch_updates_renormalises_and_reconfirms(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    item = (
        await add(
            client,
            h,
            new("onion", source="photo", quantity=3, quantity_is_estimate=True, confidence=0.8),
        )
    ).json()["items"][0]
    r = await client.patch(
        f"/v1/pantry/{item['id']}",
        json={"raw_label": "Spring onions", "quantity": 4, "storage_location": "counter"},
        headers=h,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["normalized_name"] == "scallion" and body["raw_label"] == "Spring onions"
    assert body["quantity"] == 4.0 and body["quantity_is_estimate"] is False
    assert body["storage_location"] == "counter"
    assert body["last_confirmed_at"] > item["last_confirmed_at"]
    assert body["source"] == "photo"


async def test_patch_null_clears_and_omitted_is_unchanged(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    item = (
        await add(
            client, h, new("milk", quantity=1, unit="l", storage_location="fridge", note="oat?")
        )
    ).json()["items"][0]
    r = await client.patch(f"/v1/pantry/{item['id']}", json={"note": None}, headers=h)
    body = r.json()
    assert body["note"] is None
    assert body["quantity"] == 1.0 and body["unit"] == "l" and body["storage_location"] == "fridge"
    r = await client.patch(
        f"/v1/pantry/{item['id']}", json={"quantity": None, "storage_location": None}, headers=h
    )
    body = r.json()
    assert body["quantity"] is None and body["unit"] is None and body["storage_location"] is None
    assert body["raw_label"] == "milk"
    r = await client.patch(
        f"/v1/pantry/{item['id']}", json={"quantity": 2, "unit": "cup"}, headers=h
    )
    assert (r.json()["quantity"], r.json()["unit"]) == (2.0, "cup")
    r = await client.patch(f"/v1/pantry/{item['id']}", json={"unit": None}, headers=h)
    assert (r.json()["quantity"], r.json()["unit"]) == (2.0, None)


@pytest.mark.parametrize("quantity", [5, None])
async def test_patch_quantity_always_clears_estimate(
    client: AsyncClient, quantity: float | None
) -> None:
    h = await bearer(client, "a@example.com")
    item = (
        await add(
            client,
            h,
            new("onion", source="photo", quantity=3, quantity_is_estimate=True, confidence=0.8),
        )
    ).json()["items"][0]
    assert item["quantity_is_estimate"] is True
    r = await client.patch(f"/v1/pantry/{item['id']}", json={"quantity": quantity}, headers=h)
    assert r.json()["quantity"] == (None if quantity is None else 5.0)
    assert r.json()["quantity_is_estimate"] is False


async def test_patch_without_quantity_keeps_estimate(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    item = (
        await add(
            client,
            h,
            new("onion", source="photo", quantity=3, quantity_is_estimate=True, confidence=0.8),
        )
    ).json()["items"][0]
    r = await client.patch(f"/v1/pantry/{item['id']}", json={"note": "red ones"}, headers=h)
    assert r.json()["quantity_is_estimate"] is True


@pytest.mark.parametrize(
    "patch",
    [
        {"raw_label": None},
        {"raw_label": ""},
        {"raw_label": "bad\u0000"},
        {"unit": "bunch"},
        {"source": "photo"},
        {"quantity_is_estimate": True},
        {"note": "n" * 501},
    ],
)
async def test_patch_validation(client: AsyncClient, patch: dict) -> None:
    h = await bearer(client, "a@example.com")
    item = (await add(client, h, new("honey"))).json()["items"][0]
    r = await client.patch(f"/v1/pantry/{item['id']}", json=patch, headers=h)
    assert r.status_code == 422, r.text


async def test_confirm_bumps_last_confirmed_only(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    item = (await add(client, h, new("honey", quantity=1, unit="cup"))).json()["items"][0]
    r = await client.post(f"/v1/pantry/{item['id']}/confirm", json={}, headers=h)
    assert r.status_code == 200
    body = r.json()
    assert body["last_confirmed_at"] > item["last_confirmed_at"]
    assert {k: body[k] for k in ("quantity", "unit", "raw_label")} == {
        k: item[k] for k in ("quantity", "unit", "raw_label")
    }
    assert (await client.post(f"/v1/pantry/{item['id']}/confirm", headers=h)).status_code == 200


async def test_delete(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    item = (await add(client, h, new("honey"))).json()["items"][0]
    assert (await client.delete(f"/v1/pantry/{item['id']}", headers=h)).status_code == 204
    assert (await client.get("/v1/pantry", headers=h)).json()["items"] == []
    assert (await client.delete(f"/v1/pantry/{item['id']}", headers=h)).status_code == 404


async def test_foreign_and_missing_ids_are_identical_404s(client: AsyncClient) -> None:
    """PRD §17.2 scenario 12 (pantry half): a non-owner cannot reach a pantry item."""
    a = await bearer(client, "a@example.com")
    b = await bearer(client, "b@example.com")
    item = (await add(client, a, new("honey"))).json()["items"][0]
    for target in (item["id"], str(uuid.uuid4()), "not-a-uuid"):
        for method, path, body in (
            ("PATCH", f"/v1/pantry/{target}", {"note": "mine now"}),
            ("POST", f"/v1/pantry/{target}/confirm", {}),
            ("DELETE", f"/v1/pantry/{target}", None),
        ):
            r = await client.request(method, path, json=body, headers=b)
            assert r.status_code == 404, (method, target)
            assert r.json()["error"]["code"] == "NOT_FOUND"
            assert r.json()["error"]["message"] == "Pantry item not found"
    assert (await client.get("/v1/pantry", headers=b)).json()["items"] == []
    still = (await client.get("/v1/pantry", headers=a)).json()["items"][0]
    assert still["note"] is None
