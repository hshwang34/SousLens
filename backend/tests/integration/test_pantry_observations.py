"""Pantry observations: candidates only, images never stored (PAN-02, PAN-03, PRIV-01)."""

from __future__ import annotations

import builtins
import io
import os
import tempfile
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.core.config import Settings
from app.db.engine import make_sessionmaker
from app.db.models import ObservationMode, PantryObservation, User
from app.domains.pantry.observations import RATE_LIMIT_PER_HOUR
from app.domains.pantry.upload import MAX_IMAGE_BYTES
from app.main import create_app
from tests.conftest import bearer

pytestmark = pytest.mark.usefixtures("ingredients")

JPEG = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00" + b"\x01" * 64
PNG = b"\x89PNG\r\n\x1a\n" + b"\x02" * 64
HEIC = b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00" + b"\x03" * 64
CANDIDATE_KEYS = {
    "raw_label",
    "canonical_name",
    "quantity",
    "unit",
    "quantity_is_estimate",
    "confidence",
    "confidence_bin",
    "evidence",
    "action",
    "duplicate_of",
}


async def transcript(client: AsyncClient, h: dict[str, str], said: str):
    return await client.post(
        "/v1/pantry/observations", json={"mode": "transcript", "transcript": said}, headers=h
    )


async def photo(
    client: AsyncClient,
    h: dict[str, str],
    data: bytes = JPEG,
    *,
    fixture: str | None = None,
    filename: str = "pantry.jpg",
    mime: str = "image/jpeg",
):
    fields = {"mode": "photo"}
    if fixture is not None:
        fields["fixture"] = fixture
    return await client.post(
        "/v1/pantry/observations",
        data=fields,
        files={"image": (filename, data, mime)},
        headers=h,
    )


async def pantry(client: AsyncClient, h: dict[str, str]) -> list[dict]:
    return (await client.get("/v1/pantry", headers=h)).json()["items"]


# --- transcript ---------------------------------------------------------------------------


async def test_voice_pantry_scenario_1(client: AsyncClient, engine: AsyncEngine) -> None:
    """PRD §17.2 scenario 1: candidates carry names/amounts; confirming adds only the selected."""
    h = await bearer(client, "a@example.com")
    r = await transcript(client, h, "I have half an onion, 3 pounds of chicken, gochujang")
    assert r.status_code == 201, r.text
    obs = r.json()
    assert set(obs) == {
        "observation_id",
        "mode",
        "provider",
        "candidates",
        "unknowns",
        "requires_confirmation",
        "expires_at",
    }
    assert obs["mode"] == "transcript" and obs["provider"] == "mock"
    assert obs["requires_confirmation"] is True
    expires = datetime.fromisoformat(obs["expires_at"])
    assert timedelta(hours=23, minutes=59) < expires - datetime.now(UTC) <= timedelta(hours=24)
    cands = obs["candidates"]
    assert all(set(c) == CANDIDATE_KEYS for c in cands)
    got = [(c["canonical_name"], c["quantity"], c["unit"]) for c in cands]
    assert got == [("onion", 0.5, "count"), ("chicken", 3.0, "lb"), ("gochujang", None, None)]
    assert all(c["confidence_bin"] == "high" and c["action"] == "add" for c in cands)
    assert all(c["evidence"].startswith("transcript:") for c in cands)

    # Nothing is pantry truth until the user confirms.
    assert await pantry(client, h) == []

    selected = [cands[0], cands[2]]  # the user rejects the chicken
    body = {
        "observation_id": obs["observation_id"],
        "items": [
            {
                "raw_label": c["raw_label"],
                "quantity": c["quantity"],
                "unit": c["unit"],
                "source": "voice",
                "confidence": c["confidence"],
                "quantity_is_estimate": c["quantity_is_estimate"],
            }
            for c in selected
        ],
    }
    r = await client.post("/v1/pantry", json=body, headers=h)
    assert r.status_code == 201, r.text
    names = sorted(i["normalized_name"] for i in await pantry(client, h))
    assert names == ["gochujang", "onion"]
    async with make_sessionmaker(engine)() as s:
        row = await s.get(PantryObservation, uuid.UUID(obs["observation_id"]))
        assert row is not None and row.status.value == "confirmed"
        stored = await s.execute(
            text("SELECT source_observation_id FROM pantry_items WHERE normalized_name='onion'")
        )
        assert str(stored.scalar_one()) == obs["observation_id"]


async def test_live_smoke_transcript_then_fit_marks_gochujang_available(
    client: AsyncClient,
) -> None:
    h = await bearer(client, "a@example.com")
    obs = (
        await transcript(client, h, "chicken thighs, two onions, 3 tbsp gochujang and honey")
    ).json()
    g = next(c for c in obs["candidates"] if c["canonical_name"] == "gochujang")
    assert (g["quantity"], g["unit"]) == (3.0, "tbsp")


async def test_typed_transcript_items_keep_the_client_source(client: AsyncClient) -> None:
    """iOS sends source=manual for typed text and voice for dictated text; both use
    mode=transcript. The stored source is what the client sent."""
    h = await bearer(client, "a@example.com")
    obs = (await transcript(client, h, "honey and eggs")).json()
    body = {
        "observation_id": obs["observation_id"],
        "items": [
            {
                "raw_label": "honey",
                "source": "manual",
                "confidence": 0.9,
                "quantity_is_estimate": False,
            },
            {
                "raw_label": "eggs",
                "source": "voice",
                "confidence": 0.9,
                "quantity_is_estimate": False,
            },
        ],
    }
    items = (await client.post("/v1/pantry", json=body, headers=h)).json()["items"]
    assert [(i["source"], i["confidence"]) for i in items] == [("manual", None), ("voice", 0.9)]


async def test_duplicates_are_preflagged(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    item = (
        await client.post(
            "/v1/pantry",
            json={"items": [{"raw_label": "scallions", "source": "manual"}]},
            headers=h,
        )
    ).json()["items"][0]
    cands = (await transcript(client, h, "green onions and honey")).json()["candidates"]
    assert cands[0]["duplicate_of"] == item["id"]
    assert cands[1]["duplicate_of"] is None


@pytest.mark.parametrize(
    "body",
    [
        {"mode": "transcript", "transcript": ""},
        {"mode": "transcript", "transcript": "   "},
        {"mode": "transcript", "transcript": "x" * 2001},
        {"mode": "transcript", "transcript": "eggs‮"},
        {"mode": "transcript"},
        {"mode": "photo", "transcript": "eggs"},
        {"mode": "transcript", "transcript": "eggs", "extra": 1},
    ],
)
async def test_transcript_validation(client: AsyncClient, body: dict) -> None:
    h = await bearer(client, "a@example.com")
    r = await client.post("/v1/pantry/observations", json=body, headers=h)
    assert r.status_code == 422, r.text


async def test_transcript_may_contain_newlines_and_be_2000_chars(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    said = "eggs\nhoney" + " " * 1990
    assert len(said) == 2000
    r = await transcript(client, h, said)
    assert r.status_code == 201


async def test_invalid_json_and_unsupported_content_type(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    r = await client.post(
        "/v1/pantry/observations",
        content=b"{nope",
        headers={**h, "content-type": "application/json"},
    )
    assert r.status_code == 422
    r = await client.post(
        "/v1/pantry/observations", content=b"eggs", headers={**h, "content-type": "text/plain"}
    )
    assert r.status_code == 415
    assert r.json()["error"]["code"] == "UNSUPPORTED_MEDIA_TYPE"


async def test_requires_auth(client: AsyncClient) -> None:
    r = await client.post("/v1/pantry/observations", json={"mode": "transcript", "transcript": "x"})
    assert r.status_code == 401


# --- photo --------------------------------------------------------------------------------


async def test_photo_defaults_to_demo_counter(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    r = await photo(client, h)
    assert r.status_code == 201, r.text
    obs = r.json()
    assert obs["mode"] == "photo" and obs["provider"] == "mock"
    cands = obs["candidates"]
    assert 5 <= len(cands) <= 7
    jar = next(c for c in cands if c["raw_label"] == "unlabeled jar")
    assert jar["canonical_name"] is None
    assert jar["confidence_bin"] == "unknown" and jar["action"] == "ignore"
    onion = next(c for c in cands if c["canonical_name"] == "onion")
    assert onion["quantity"] == 3.0 and onion["unit"] == "count"
    assert onion["quantity_is_estimate"] is True
    assert all(c["quantity"] is None for c in cands if c is not onion)
    assert "contents of the unlabeled jar" in obs["unknowns"]
    assert {c["confidence_bin"] for c in cands} == {"high", "medium", "unknown"}
    assert await pantry(client, h) == []


@pytest.mark.parametrize(
    ("data", "name", "mime"),
    [(PNG, "a.png", "image/png"), (HEIC, "a.heic", "image/heic")],
)
async def test_png_and_heic_are_accepted(
    client: AsyncClient, data: bytes, name: str, mime: str
) -> None:
    h = await bearer(client, "a@example.com")
    assert (await photo(client, h, data, filename=name, mime=mime)).status_code == 201


async def test_blurry_photo_is_uncertain_not_authoritative(client: AsyncClient) -> None:
    """PRD §17.2 scenario 2: blurred / missing-label → uncertain, never high confidence."""
    h = await bearer(client, "a@example.com")
    obs = (await photo(client, h, fixture="blurry_shelf")).json()
    cands = obs["candidates"]
    assert cands
    assert all(c["confidence_bin"] in ("medium", "unknown") for c in cands)
    assert all(c["action"] == "ignore" for c in cands if c["confidence_bin"] == "unknown")
    assert obs["unknowns"]
    assert await pantry(client, h) == []


async def test_gochujang_jar_fixture_still_works(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    obs = (await photo(client, h, fixture="gochujang_jar")).json()
    assert [c["raw_label"] for c in obs["candidates"]] == ["Gochujang", "unlabeled jar"]
    assert obs["unknowns"] == ["unlabeled jar: contents not identifiable"]


async def test_unknown_fixture_is_unknown_not_fabricated(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    obs = (await photo(client, h, fixture="nope")).json()
    assert [c["canonical_name"] for c in obs["candidates"]] == [None]


async def test_bad_fixture_name_is_422(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    assert (await photo(client, h, fixture="../../etc/passwd")).status_code == 422


@pytest.fixture
async def gemini_client(settings: Settings, clean_tables: None) -> AsyncIterator[AsyncClient]:
    app = create_app(settings.model_copy(update={"ai_provider": "gemini"}))
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as c:
            yield c


async def test_fixture_field_is_ignored_outside_mock(gemini_client: AsyncClient) -> None:
    h = await bearer(gemini_client, "a@example.com")
    # Even a crafted fixture name never selects a file when the provider is not the mock; the
    # Gemini stub refuses (Slice 4) and nothing is stored.
    r = await photo(gemini_client, h, fixture="blurry_shelf")
    assert r.status_code == 503
    assert r.json()["error"]["code"] == "PROVIDER_NOT_CONFIGURED"


@pytest.mark.parametrize(
    ("data", "name", "mime"),
    [
        (b"GIF89a" + b"\x00" * 32, "a.gif", "image/gif"),
        (b"%PDF-1.7 hello", "a.jpg", "image/jpeg"),  # lies about its type
        (b"<svg xmlns='http://www.w3.org/2000/svg'/>", "a.png", "image/png"),
    ],
)
async def test_non_images_are_415(client: AsyncClient, data: bytes, name: str, mime: str) -> None:
    h = await bearer(client, "a@example.com")
    r = await photo(client, h, data, filename=name, mime=mime)
    assert r.status_code == 415
    assert r.json()["error"]["code"] == "UNSUPPORTED_MEDIA_TYPE"


async def test_image_over_5_000_000_bytes_is_413(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    assert MAX_IMAGE_BYTES == 5_000_000
    ok = JPEG + b"\x00" * (MAX_IMAGE_BYTES - len(JPEG))
    assert (await photo(client, h, ok)).status_code == 201
    r = await photo(client, h, ok + b"\x00")
    assert r.status_code == 413
    assert r.json()["error"]["code"] == "PAYLOAD_TOO_LARGE"
    r = await photo(client, h, JPEG + b"\x00" * (8 * 1024 * 1024))
    assert r.status_code == 413


async def test_photo_mode_requires_an_image_file(client: AsyncClient) -> None:
    h = await bearer(client, "a@example.com")
    # Form-urlencoded is not multipart: 415.
    r = await client.post("/v1/pantry/observations", data={"mode": "photo"}, headers=h)
    assert r.status_code == 415
    r = await client.post("/v1/pantry/observations", files={"mode": (None, "photo")}, headers=h)
    assert r.status_code == 422
    r = await client.post(
        "/v1/pantry/observations",
        data={"mode": "video"},
        files={"image": ("a.jpg", JPEG)},
        headers=h,
    )
    assert r.status_code == 422


def _snapshot(root: Path) -> list[Path]:
    return sorted(root.rglob("*")) if root.exists() else []


async def test_image_bytes_are_never_written_to_disk_or_db(
    client: AsyncClient,
    engine: AsyncEngine,
    settings: Settings,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """PRIV-01: a 2 MB photo (above Starlette's 1 MB spool threshold) is handled entirely in
    memory: no file is opened for writing, no temp file is created, the media dir is untouched,
    and only candidate JSON lands in the database."""
    h = await bearer(client, "a@example.com")
    marker = b"PRIVATE-KITCHEN-PIXELS-" + uuid.uuid4().hex.encode()
    image = JPEG + marker + b"\x00" * (2 * 1024 * 1024)
    media_root = Path(settings.media_root)
    before = _snapshot(media_root)

    writes: list[str] = []
    real_open, real_io_open, real_os_open = builtins.open, io.open, os.open

    def guard_open(file, mode="r", *a, **kw):  # type: ignore[no-untyped-def]
        if any(m in str(mode) for m in ("w", "a", "x", "+")):
            writes.append(f"open({file!r}, {mode!r})")
        return real_open(file, mode, *a, **kw)

    def guard_io_open(file, mode="r", *a, **kw):  # type: ignore[no-untyped-def]
        if any(m in str(mode) for m in ("w", "a", "x", "+")):
            writes.append(f"io.open({file!r}, {mode!r})")
        return real_io_open(file, mode, *a, **kw)

    def guard_os_open(path, flags, *a, **kw):  # type: ignore[no-untyped-def]
        if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT):
            writes.append(f"os.open({path!r})")
        return real_os_open(path, flags, *a, **kw)

    def forbidden(name: str):  # type: ignore[no-untyped-def]
        def _raise(*a, **kw):  # type: ignore[no-untyped-def]
            writes.append(name)
            raise AssertionError(f"{name} called while handling a pantry photo")

        return _raise

    monkeypatch.setattr(builtins, "open", guard_open)
    monkeypatch.setattr(io, "open", guard_io_open)
    monkeypatch.setattr(os, "open", guard_os_open)
    for name in (
        "SpooledTemporaryFile",
        "TemporaryFile",
        "NamedTemporaryFile",
        "mkstemp",
        "mkdtemp",
    ):
        monkeypatch.setattr(tempfile, name, forbidden(f"tempfile.{name}"))

    r = await photo(client, h, image)
    monkeypatch.undo()
    assert r.status_code == 201, r.text
    assert writes == []
    after = _snapshot(media_root)
    assert after == before

    async with engine.connect() as conn:
        dump = await conn.execute(text("SELECT row_to_json(o)::text FROM pantry_observations o"))
        rows = [row[0] for row in dump]
    assert len(rows) == 1
    assert marker.decode() not in rows[0]
    cols = await engine.connect()
    try:
        names = await cols.execute(
            text(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_name IN ('pantry_observations', 'pantry_items')"
            )
        )
        assert not [n for (n,) in names if "image" in n or "media" in n]
    finally:
        await cols.close()


# --- TTL, purge, rate limit -----------------------------------------------------------------


async def _user_id(engine: AsyncEngine, email: str) -> uuid.UUID:
    async with make_sessionmaker(engine)() as s:
        return (await s.execute(select(User.id).where(User.email == email))).scalar_one()


async def test_expired_observations_are_purged_and_cannot_be_confirmed(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    h = await bearer(client, "a@example.com")
    obs = (await transcript(client, h, "honey")).json()
    async with engine.begin() as conn:
        await conn.execute(
            text("UPDATE pantry_observations SET expires_at = now() - interval '1 minute'")
        )
    body = {
        "observation_id": obs["observation_id"],
        "items": [{"raw_label": "honey", "source": "voice", "confidence": 0.9}],
    }
    r = await client.post("/v1/pantry", json=body, headers=h)
    assert r.status_code == 404
    assert await pantry(client, h) == []
    # A new observation purges the expired row.
    await transcript(client, h, "eggs")
    async with engine.connect() as conn:
        ids = [str(i) for (i,) in await conn.execute(text("SELECT id FROM pantry_observations"))]
    assert obs["observation_id"] not in ids and len(ids) == 1


async def test_observation_of_another_user_is_404(client: AsyncClient) -> None:
    a = await bearer(client, "a@example.com")
    b = await bearer(client, "b@example.com")
    obs = (await transcript(client, a, "honey")).json()
    body = {
        "observation_id": obs["observation_id"],
        "items": [{"raw_label": "honey", "source": "voice"}],
    }
    r = await client.post("/v1/pantry", json=body, headers=b)
    assert r.status_code == 404
    assert await pantry(client, b) == []


async def test_rate_limit_30_per_hour(client: AsyncClient, engine: AsyncEngine) -> None:
    h = await bearer(client, "a@example.com")
    uid = await _user_id(engine, "a@example.com")
    other = await bearer(client, "b@example.com")
    now = datetime.now(UTC)
    async with make_sessionmaker(engine)() as s:
        # Old rows (outside the hour) don't count.
        for minutes in [90] * 5 + [10] * (RATE_LIMIT_PER_HOUR - 1):
            s.add(
                PantryObservation(
                    owner_user_id=uid,
                    mode=ObservationMode.TRANSCRIPT,
                    candidate_json=[],
                    created_at=now - timedelta(minutes=minutes),
                    expires_at=now + timedelta(hours=20),
                )
            )
        await s.commit()
    assert (await transcript(client, h, "honey")).status_code == 201  # the 30th
    r = await transcript(client, h, "honey")
    assert r.status_code == 429
    assert r.json()["error"]["code"] == "RATE_LIMITED"
    assert r.json()["error"]["retryable"] is True
    assert (await photo(client, h)).status_code == 429
    assert (await transcript(client, other, "honey")).status_code == 201  # per user
