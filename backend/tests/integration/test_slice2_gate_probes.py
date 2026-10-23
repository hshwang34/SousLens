"""QA gate probes for Slice 2 (brief 004), backend half. Real Postgres.

Covers: no silent pantry writes and transactional 409/422, merge identity rules, fit staleness
and access, photo handling (magic bytes, garbage after a valid header, size edges, a canary that
proves the no-disk-write guard actually trips on Starlette's spooling path), rate limiting and
expired observations.
"""

from __future__ import annotations

import asyncio
import builtins
import io
import os
import tempfile
import uuid

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from app.domains.pantry.observations import RATE_LIMIT_PER_HOUR
from app.domains.pantry.upload import MAX_IMAGE_BYTES
from app.scripts.seed import seed_fixtures, seed_uuid
from tests.conftest import FIXTURES_DIR, bearer

pytestmark = pytest.mark.usefixtures("ingredients")

JPEG = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00" + b"\x01" * 64
GOCHUJANG_V1 = seed_uuid("version", "gochujang-chicken-thighs:1")


def new(label: str, **kw: object) -> dict[str, object]:
    item: dict[str, object] = {"raw_label": label, "source": "manual"}
    item.update(kw)
    return item


async def post_items(client, h, *items, obs=None):  # type: ignore[no-untyped-def]
    return await client.post(
        "/v1/pantry", json={"items": list(items), "observation_id": obs}, headers=h
    )


async def seed_pantry(client, h, *items):  # type: ignore[no-untyped-def]
    r = await post_items(client, h, *items)
    assert r.status_code == 201, r.text
    return r.json()["items"]


async def transcript(client, h, said):  # type: ignore[no-untyped-def]
    return await client.post(
        "/v1/pantry/observations", json={"mode": "transcript", "transcript": said}, headers=h
    )


async def photo(client, h, data=JPEG, **fields):  # type: ignore[no-untyped-def]
    return await client.post(
        "/v1/pantry/observations",
        data={"mode": "photo", **fields},
        files={"image": ("p.jpg", data, "image/jpeg")},
        headers=h,
    )


async def dump(engine: AsyncEngine, table: str = "pantry_items") -> list[str]:
    async with engine.connect() as conn:
        rows = await conn.execute(text(f"SELECT row_to_json(t)::text FROM {table} t ORDER BY id"))
        return [r[0] for r in rows]


# --- 1. no silent pantry writes -----------------------------------------------------------------


async def test_creating_observations_never_touches_pantry_items(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "a@example.com")
    await seed_pantry(client, h, new("honey", quantity=1, unit="cup"), new("garlic"))
    before = await dump(engine)
    assert len(before) == 2
    for said in ("honey, eggs, 3 onions", "um uh", "gochujang"):
        assert (await transcript(client, h, said)).status_code == 201
    for fixture in ("demo_counter", "blurry_shelf", "gochujang_jar", "nope"):
        assert (await photo(client, h, fixture=fixture)).status_code == 201
    assert await dump(engine) == before  # identical rows, byte for byte (incl. updated_at)
    assert len(await dump(engine, "pantry_observations")) == 7


async def test_filler_only_transcript_is_an_empty_candidate_list_not_an_error(
    client: AsyncClient,
) -> None:
    h = await bearer(client, "a@example.com")
    r = await transcript(client, h, "um uh")
    assert r.status_code == 201
    assert r.json()["candidates"] == [] and r.json()["requires_confirmation"] is True


async def test_confirm_writes_only_the_items_sent(client: AsyncClient, engine: AsyncEngine) -> None:
    h = await bearer(client, "a@example.com")
    obs = (await transcript(client, h, "honey, eggs, 3 onions, garlic")).json()
    assert len(obs["candidates"]) == 4
    stored_before = await dump(engine, "pantry_observations")
    r = await post_items(
        client, h, new("eggs", source="voice", confidence=0.9), obs=obs["observation_id"]
    )
    assert r.status_code == 201
    assert [i["normalized_name"] for i in r.json()["items"]] == ["egg"]
    rows = (await client.get("/v1/pantry", headers=h)).json()["items"]
    assert [i["normalized_name"] for i in rows] == ["egg"]
    # the stored candidate list is not a pantry and is not rewritten except for its status
    async with engine.connect() as conn:
        n = await conn.scalar(text("SELECT count(*) FROM pantry_items"))
    assert n == 1
    assert len(stored_before) == 1


async def test_409_is_fully_transactional_even_with_valid_merges_and_an_observation(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "a@example.com")
    honey, garlic = await seed_pantry(
        client, h, new("honey", quantity=1, unit="cup"), new("garlic", quantity=2)
    )
    obs = (await transcript(client, h, "eggs")).json()
    before_items = await dump(engine)
    before_obs = await dump(engine, "pantry_observations")
    r = await post_items(
        client,
        h,
        new("garlic", quantity=9, resolution={"merge_into": garlic["id"]}),  # valid merge
        new("eggs"),  # valid new
        new("honeys", quantity=5),  # duplicate, no resolution -> 409
        obs=obs["observation_id"],
    )
    assert r.status_code == 409, r.text
    assert r.json()["error"]["code"] == "DUPLICATE_PANTRY_ITEM"
    assert [c["index"] for c in r.json()["error"]["details"]["conflicts"]] == [2]
    assert r.json()["error"]["details"]["conflicts"][0]["existing"]["id"] == honey["id"]
    assert await dump(engine) == before_items
    assert await dump(engine, "pantry_observations") == before_obs  # still pending


async def test_422_after_valid_items_writes_nothing(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "a@example.com")
    other = await bearer(client, "b@example.com")
    (theirs,) = await seed_pantry(client, other, new("honey"))
    (mine,) = await seed_pantry(client, h, new("honey", quantity=1, unit="cup"))
    before = await dump(engine)
    r = await post_items(
        client,
        h,
        new("honey", quantity=7, resolution={"merge_into": mine["id"]}),
        new("eggs"),
        new("honey", resolution={"merge_into": theirs["id"]}),
    )
    assert r.status_code == 422
    assert await dump(engine) == before


async def test_failure_after_mutations_rolls_the_whole_request_back(
    client: AsyncClient, engine: AsyncEngine, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Even a crash mid-write (here: the post-flush refresh blows up) leaves no partial state."""
    h = await bearer(client, "a@example.com")
    (honey,) = await seed_pantry(client, h, new("honey", quantity=1, unit="cup"))
    before = await dump(engine)

    async def boom(self, *a, **kw):  # type: ignore[no-untyped-def]
        raise RuntimeError("simulated failure after flush")

    monkeypatch.setattr(AsyncSession, "refresh", boom)
    r = await post_items(
        client,
        h,
        new("honey", quantity=9, resolution={"merge_into": honey["id"]}),
        new("eggs"),
    )
    monkeypatch.undo()
    assert r.status_code == 500
    assert await dump(engine) == before


# --- 2. duplicate / merge identity --------------------------------------------------------------


@pytest.mark.parametrize(
    ("existing", "incoming"),
    [
        ("gochugaru", "gochujang"),
        ("gochujang", "gochugaru"),
        ("cooked rice", "rice"),
        ("rice", "cooked rice"),
        ("raw rice", "cooked rice"),
        ("peanut butter", "almond butter"),
    ],
)
async def test_merge_into_a_different_identity_is_rejected_and_writes_nothing(
    client: AsyncClient, engine: AsyncEngine, existing: str, incoming: str
) -> None:
    h = await bearer(client, "a@example.com")
    (target,) = await seed_pantry(client, h, new(existing, quantity=1, unit="cup"))
    before = await dump(engine)
    r = await post_items(
        client, h, new(incoming, quantity=5, resolution={"merge_into": target["id"]})
    )
    assert r.status_code == 422, r.text
    assert r.json()["error"]["fields"] == ["items.0.resolution.merge_into"]
    assert await dump(engine) == before


async def test_merge_into_a_foreign_item_is_rejected_leaks_nothing_and_writes_nothing(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    a = await bearer(client, "a@example.com")
    b = await bearer(client, "b@example.com")
    (theirs,) = await seed_pantry(client, b, new("honey", quantity=1, unit="cup"))
    before = await dump(engine)
    r = await post_items(
        client, a, new("honey", quantity=5, resolution={"merge_into": theirs["id"]})
    )
    assert r.status_code == 422
    assert theirs["id"] not in r.text and "cup" not in r.text  # nothing of B's row is echoed
    assert await dump(engine) == before
    # identical response for a made-up id: existence of B's item is not observable
    r2 = await post_items(
        client, a, new("honey", quantity=5, resolution={"merge_into": str(uuid.uuid4())})
    )
    assert r2.status_code == r.status_code
    assert r2.json()["error"]["message"] == r.json()["error"]["message"]


async def test_keep_both_adds_a_second_row_and_leaves_the_first_untouched(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "a@example.com")
    (first,) = await seed_pantry(client, h, new("eggs", quantity=2))
    before = (await dump(engine))[0]
    r = await post_items(client, h, new("egg", quantity=6, resolution={"keep_both": True}))
    assert r.status_code == 201 and r.json()["items"][0]["id"] != first["id"]
    rows = await dump(engine)
    assert len(rows) == 2 and before in rows


async def test_get_pantry_is_sorted_by_normalized_name(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    await seed_pantry(client, h, new("Zucchini"), new("apples"), new("Honey"), new("scallions"))
    names = [
        i["normalized_name"] for i in (await client.get("/v1/pantry", headers=h)).json()["items"]
    ]
    assert names == sorted(names) == ["apple", "honey", "scallion", "zucchini"]


# --- 5. fit staleness through the API + access --------------------------------------------------


@pytest.fixture
async def seeded(db_session) -> None:  # type: ignore[no-untyped-def]
    await seed_fixtures(db_session, FIXTURES_DIR)


@pytest.mark.usefixtures("seeded")
@pytest.mark.parametrize(
    ("age", "status"),
    [
        ("13 days 23 hours", "available"),
        ("14 days 1 minute", "uncertain"),
    ],
)
async def test_fit_staleness_boundary_via_api(
    client: AsyncClient, engine: AsyncEngine, age: str, status: str
) -> None:
    h = await bearer(client, "a@example.com")
    await seed_pantry(client, h, new("honey", quantity=1, unit="cup"))
    async with engine.begin() as conn:
        await conn.execute(
            text(f"UPDATE pantry_items SET last_confirmed_at = now() - interval '{age}'")
        )
    r = await client.post(f"/v1/recipe-versions/{GOCHUJANG_V1}/fit", json={}, headers=h)
    honey = next(i for i in r.json()["items"] if i["name"].lower().startswith("honey"))
    assert honey["status"] == status, honey["reason"]


@pytest.mark.usefixtures("seeded")
async def test_fit_reads_only_the_callers_pantry(client: AsyncClient) -> None:
    a = await bearer(client, "a@example.com")
    b = await bearer(client, "b@example.com")
    await seed_pantry(client, a, new("honey", quantity=1, unit="cup"))
    r = await client.post(f"/v1/recipe-versions/{GOCHUJANG_V1}/fit", json={}, headers=b)
    assert r.json()["counts"]["available"] == 0
    assert all(i["pantry_item_id"] is None for i in r.json()["items"])


# --- 6. photo -----------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "brand", [b"heic", b"heix", b"hevc", b"hevx", b"heim", b"heis", b"mif1", b"msf1"]
)
async def test_every_heic_brand_is_accepted_by_magic_bytes(
    client: AsyncClient, brand: bytes
) -> None:
    h = await bearer(client, "a@example.com")
    data = b"\x00\x00\x00\x18ftyp" + brand + b"\x00" * 32
    r = await client.post(
        "/v1/pantry/observations",
        data={"mode": "photo"},
        files={"image": ("a.heic", data, "application/octet-stream")},  # client MIME is ignored
        headers=h,
    )
    assert r.status_code == 201, r.text


@pytest.mark.parametrize(
    "data",
    [
        b"\x00\x00\x00\x18ftypavif" + b"\x00" * 16,
        b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 16,  # a video container
        b"\xff\xd8",  # truncated JPEG magic
        b"RIFF\x00\x00\x00\x00WEBP",
        b"",
    ],
)
async def test_other_containers_and_truncated_magic_are_rejected(
    client: AsyncClient, data: bytes
) -> None:
    h = await bearer(client, "a@example.com")
    r = await photo(client, h, data)
    assert r.status_code in (415, 422), (r.status_code, r.text)


async def test_jpeg_header_followed_by_garbage_reaches_the_model_but_nothing_is_stored(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "a@example.com")
    provider = client._transport.app.state.ai_provider  # type: ignore[attr-defined]
    seen: list[bytes | None] = []
    real = provider.observe

    async def spy(request):  # type: ignore[no-untyped-def]
        seen.append(request.image_bytes)
        return await real(request)

    provider.observe = spy
    garbage = JPEG + os.urandom(2048) + b"NOT-A-REAL-JPEG-MARKER"
    try:
        r = await photo(client, h, garbage)
    finally:
        del provider.observe
    assert r.status_code == 201, r.text  # magic bytes only; the model decides what it sees
    assert seen == [garbage]
    dumped = "".join(await dump(engine, "pantry_observations"))
    assert "NOT-A-REAL-JPEG-MARKER" not in dumped
    assert await dump(engine) == []
    async with engine.connect() as conn:
        n = await conn.scalar(text("SELECT count(*) FROM pantry_observations"))
    assert n == 1


async def test_exactly_5_000_000_bytes_ok_and_one_more_is_413_with_nothing_stored(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "a@example.com")
    ok = JPEG + b"\x00" * (MAX_IMAGE_BYTES - len(JPEG))
    assert len(ok) == 5_000_000
    assert (await photo(client, h, ok)).status_code == 201
    r = await photo(client, h, ok + b"\x00")
    assert r.status_code == 413 and r.json()["error"]["code"] == "PAYLOAD_TOO_LARGE"
    assert len(await dump(engine, "pantry_observations")) == 1


async def test_chunked_oversized_body_without_content_length_is_413(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    boundary = "bnd"
    head = (
        f'--{boundary}\r\nContent-Disposition: form-data; name="mode"\r\n\r\nphoto\r\n'
        f'--{boundary}\r\nContent-Disposition: form-data; name="image"; filename="a.jpg"\r\n'
        "Content-Type: image/jpeg\r\n\r\n"
    ).encode()
    tail = f"\r\n--{boundary}--\r\n".encode()

    async def body():  # type: ignore[no-untyped-def]
        yield head + JPEG
        for _ in range(7):
            yield b"\x00" * 1_000_000
        yield tail

    r = await client.post(
        "/v1/pantry/observations",
        content=body(),
        headers={**h, "content-type": f"multipart/form-data; boundary={boundary}"},
    )
    assert r.status_code == 413, r.text


class _WriteGuard:
    """Records any attempt to create a file or temp file (same guard as the PRIV-01 test)."""

    def __init__(self, monkeypatch: pytest.MonkeyPatch) -> None:
        self.writes: list[str] = []
        real_open, real_io_open, real_os_open = builtins.open, io.open, os.open

        def guard_open(file, mode="r", *a, **kw):  # type: ignore[no-untyped-def]
            if any(m in str(mode) for m in ("w", "a", "x", "+")):
                self.writes.append(f"open({file!r})")
            return real_open(file, mode, *a, **kw)

        def guard_io_open(file, mode="r", *a, **kw):  # type: ignore[no-untyped-def]
            if any(m in str(mode) for m in ("w", "a", "x", "+")):
                self.writes.append(f"io.open({file!r})")
            return real_io_open(file, mode, *a, **kw)

        def guard_os_open(path, flags, *a, **kw):  # type: ignore[no-untyped-def]
            if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT):
                self.writes.append(f"os.open({path!r})")
            return real_os_open(path, flags, *a, **kw)

        monkeypatch.setattr(builtins, "open", guard_open)
        monkeypatch.setattr(io, "open", guard_io_open)
        monkeypatch.setattr(os, "open", guard_os_open)
        for name in ("SpooledTemporaryFile", "TemporaryFile", "NamedTemporaryFile", "mkstemp"):
            monkeypatch.setattr(
                tempfile, name, self._record(f"tempfile.{name}", getattr(tempfile, name))
            )

    def _record(self, name, real):  # type: ignore[no-untyped-def]
        def wrapper(*a, **kw):  # type: ignore[no-untyped-def]
            self.writes.append(name)
            return real(*a, **kw)

        return wrapper


async def test_write_guard_canary_trips_on_starlettes_form_spooling(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Meaningfulness check for the PRIV-01 no-disk-write test: the same guard, applied to a
    Starlette endpoint that uses ``request.form()`` (the naive implementation), must see a
    temp-file write for a 2 MB upload. If this ever passes with no writes, the guard in
    test_image_bytes_are_never_written_to_disk_or_db proves nothing."""

    async def naive(request: Request) -> JSONResponse:
        form = await request.form()
        return JSONResponse({"n": len(await form["image"].read())})

    app = Starlette(routes=[Route("/up", naive, methods=["POST"])])
    guard = _WriteGuard(monkeypatch)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
        r = await c.post(
            "/up", files={"image": ("a.jpg", JPEG + b"\x00" * (2 * 1024 * 1024), "image/jpeg")}
        )
    monkeypatch.undo()
    assert r.status_code == 200
    assert guard.writes, "the guard did not notice Starlette's >1 MB spool to disk"


async def test_real_endpoint_with_a_6_mb_photo_trips_no_write_guard_at_all(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Same guard, our endpoint, a body well above the 1 MB spool threshold, up to the cap."""
    h = await bearer(client, "a@example.com")
    guard = _WriteGuard(monkeypatch)
    r = await photo(client, h, JPEG + b"\x07" * (MAX_IMAGE_BYTES - len(JPEG)))
    monkeypatch.undo()
    assert r.status_code == 201
    assert guard.writes == []


# --- 7. rate limit ------------------------------------------------------------------------------


async def test_failed_requests_do_not_count_toward_the_limit(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    for _ in range(RATE_LIMIT_PER_HOUR + 5):
        assert (
            await client.post(
                "/v1/pantry/observations", json={"mode": "transcript", "transcript": ""}, headers=h
            )
        ).status_code == 422
        assert (await photo(client, h, b"GIF89a....")).status_code == 415
        assert (
            await client.post(
                "/v1/pantry/observations", content=b"x", headers={**h, "content-type": "text/plain"}
            )
        ).status_code == 415
    for i in range(RATE_LIMIT_PER_HOUR):
        assert (await transcript(client, h, f"honey {i}")).status_code == 201, i
    r = await transcript(client, h, "honey")
    assert r.status_code == 429 and r.json()["error"]["code"] == "RATE_LIMITED"
    # a 429 does not itself extend the window / create rows
    assert (await photo(client, h)).status_code == 429


async def test_rate_limit_is_per_user_and_exact_under_concurrency(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    a = await bearer(client, "a@example.com")
    b = await bearer(client, "b@example.com")
    results = await asyncio.gather(*(transcript(client, a, "honey") for _ in range(40)))
    codes = sorted(r.status_code for r in results)
    assert codes.count(201) == RATE_LIMIT_PER_HOUR, codes
    assert codes.count(429) == 10
    assert (await transcript(client, b, "honey")).status_code == 201
    async with engine.connect() as conn:
        n = await conn.scalar(text("SELECT count(*) FROM pantry_observations"))
    assert n == RATE_LIMIT_PER_HOUR + 1


async def test_observations_older_than_an_hour_age_out_of_the_window(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "a@example.com")
    for _ in range(RATE_LIMIT_PER_HOUR):
        assert (await transcript(client, h, "honey")).status_code == 201
    assert (await transcript(client, h, "honey")).status_code == 429
    async with engine.begin() as conn:
        await conn.execute(
            text("UPDATE pantry_observations SET created_at = now() - interval '61 minutes'")
        )
    assert (await transcript(client, h, "honey")).status_code == 201


# --- 8. expired observation on confirm ----------------------------------------------------------


async def test_confirm_with_an_expired_observation_is_404_and_writes_nothing_at_all(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    """Behaviour under test (report item): the observation id is validated first and the
    whole request fails with 404 "Observation not found". The items are NOT written (not even
    without provenance) and the expired row is left in place until the next scan purges it."""
    h = await bearer(client, "a@example.com")
    obs = (await transcript(client, h, "honey")).json()
    async with engine.begin() as conn:
        await conn.execute(
            text("UPDATE pantry_observations SET expires_at = now() - interval '1 second'")
        )
    before = await dump(engine, "pantry_observations")
    r = await post_items(
        client, h, new("honey", source="voice", confidence=0.9), obs=obs["observation_id"]
    )
    assert r.status_code == 404
    assert r.json()["error"]["message"] == "Observation not found"
    assert await dump(engine) == []
    assert await dump(engine, "pantry_observations") == before
    # the user's way out: resend the same items without observation_id
    assert (
        await post_items(client, h, new("honey", source="voice", confidence=0.9))
    ).status_code == 201


async def test_just_inside_the_ttl_still_confirms_and_a_confirmed_observation_cannot_be_relinked(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "a@example.com")
    obs = (await transcript(client, h, "honey, eggs")).json()
    async with engine.begin() as conn:
        await conn.execute(
            text("UPDATE pantry_observations SET expires_at = now() + interval '1 minute'")
        )
    assert (
        await post_items(client, h, new("honey", source="voice"), obs=obs["observation_id"])
    ).status_code == 201
    # fix round 1, item 7: a confirmed observation cannot be linked again (409, no write)
    r = await post_items(client, h, new("eggs", source="voice"), obs=obs["observation_id"])
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "STATE_CONFLICT"
    assert r.json()["error"]["message"] == "These items were already added"
    assert [
        i["normalized_name"] for i in (await client.get("/v1/pantry", headers=h)).json()["items"]
    ] == ["honey"]
