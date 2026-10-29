"""Brief 008 end to end: own-video upload through a presigned URL (moto S3), the extraction
worker (real ffprobe/ffmpeg on a generated 5 s clip), the review → publish → play-clips gate,
trim, media retention, limits, ownership, and the worker's claim / retry / crash-resume rules.
The Gemini path replays hand-written fixtures; nothing touches the network."""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import AsyncIterator
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select, text, update

from app.ai.budget import CostGuard, Reservation
from app.ai.providers.base import ExtractionRequest
from app.ai.providers.mock import MockAIProvider
from app.core.config import Settings
from app.core.errors import ProviderUnavailable
from app.db.models import (
    AIUsage,
    DraftStatus,
    ExtractionJob,
    ExtractionStatus,
    MediaConsent,
    MediaDeletion,
    RecipeDraft,
    RecipeMedia,
    User,
)
from app.main import create_app
from app.media import ffmpeg
from app.media.storage import S3Storage
from app.workers.extraction import ExtractionWorker
from tests.conftest import FIXTURES_DIR, bearer
from tests.gemini_fake import FakeTransport, fake_provider

MP4 = "video/mp4"


@dataclass
class Env:
    client: AsyncClient
    app: FastAPI
    storage: S3Storage
    settings: Settings
    video: Path
    workdir: Path

    def worker(self, provider: object | None = None, **overrides: Any) -> ExtractionWorker:
        return ExtractionWorker(
            self.app.state.sessionmaker,
            self.settings.model_copy(update=overrides),
            storage=self.storage,
            provider=provider or self.app.state.ai_provider,
            guard=self.app.state.cost_guard,
            worker_id=f"w-{uuid.uuid4().hex[:6]}",
            workdir=self.workdir,
        )


async def _env(
    settings: Settings, storage: S3Storage, video: Path, tmp_path: Path, provider: Any = None
) -> AsyncIterator[Env]:
    app = create_app(settings)
    app.state.storage = storage
    if provider is not None:
        app.state.ai_provider = provider
    async with app.router.lifespan_context(app):
        async with AsyncClient(
            transport=ASGITransport(app=app, raise_app_exceptions=False), base_url="http://test"
        ) as client:
            yield Env(client, app, storage, settings, video, tmp_path / "work")


@pytest.fixture
async def env(
    settings: Settings, clean_tables: None, s3_storage: S3Storage, test_video: Path, tmp_path: Path
) -> AsyncIterator[Env]:
    async for e in _env(settings, s3_storage, test_video, tmp_path):
        yield e


@pytest.fixture
def transport() -> FakeTransport:
    return FakeTransport()


@pytest.fixture
async def genv(
    settings: Settings,
    clean_tables: None,
    s3_storage: S3Storage,
    test_video: Path,
    tmp_path: Path,
    transport: FakeTransport,
) -> AsyncIterator[Env]:
    gsettings = settings.model_copy(update={"ai_provider": "gemini"})
    async for e in _env(
        gsettings, s3_storage, test_video, tmp_path, provider=fake_provider(gsettings, transport)
    ):
        yield e


# --- helpers -------------------------------------------------------------------------------


def intent_body(**overrides: Any) -> dict[str, Any]:
    body: dict[str, Any] = {
        "content_type": MP4,
        "size_bytes": 1000,
        "duration_ms": 5000,
        "owns_rights": True,
    }
    body.update(overrides)
    return body


def key_from_url(url: str, bucket: str) -> str:
    path = urlsplit(url).path.lstrip("/")
    assert path.startswith(bucket + "/")
    return path[len(bucket) + 1 :]


async def put_object(env: Env, url: str, data: bytes, content_type: str = MP4) -> None:
    key = key_from_url(url, env.storage.bucket)
    await asyncio.to_thread(
        env.storage.client.put_object,
        Bucket=env.storage.bucket,
        Key=key,
        Body=data,
        ContentType=content_type,
    )


async def upload(
    env: Env,
    headers: dict[str, str],
    data: bytes | None = None,
    *,
    title_hint: str | None = None,
) -> dict[str, Any]:
    """Phone flow: intent → PUT to the presigned URL → mark uploaded. Returns the job."""
    payload = data if data is not None else env.video.read_bytes()
    res = await env.client.post(
        "/v1/media/upload-intents", json=intent_body(size_bytes=len(payload)), headers=headers
    )
    assert res.status_code == 201, res.text
    intent = res.json()
    await put_object(env, intent["upload_url"], payload)
    body = {"title_hint": title_hint} if title_hint else None
    res = await env.client.post(
        f"/v1/media/{intent['media_id']}/uploaded", json=body, headers=headers
    )
    assert res.status_code == 202, res.text
    return res.json()


async def job(env: Env, headers: dict[str, str], job_id: str) -> dict[str, Any]:
    res = await env.client.get(f"/v1/extractions/{job_id}", headers=headers)
    assert res.status_code == 200, res.text
    return res.json()


async def draft(env: Env, headers: dict[str, str], draft_id: str) -> dict[str, Any]:
    res = await env.client.get(f"/v1/recipes/drafts/{draft_id}", headers=headers)
    assert res.status_code == 200, res.text
    return res.json()


async def exists(env: Env, key: str) -> bool:
    return await env.storage.head(key) is not None


async def media_row(env: Env, media_id: str | uuid.UUID) -> RecipeMedia | None:
    async with env.app.state.sessionmaker() as s:
        return await s.get(RecipeMedia, uuid.UUID(str(media_id)))


async def run_all(worker: ExtractionWorker) -> int:
    n = 0
    while await worker.run_once():
        n += 1
    await worker.drain_deletions()
    return n


async def ready_extraction(env: Env, headers: dict[str, str]) -> tuple[dict, dict]:
    started = await upload(env, headers)
    await run_all(env.worker())
    done = await job(env, headers, started["id"])
    assert done["status"] == "ready", done
    return done, await draft(env, headers, done["draft_id"])


async def user_id(env: Env, email: str) -> uuid.UUID:
    async with env.app.state.sessionmaker() as s:
        return (await s.execute(select(User.id).where(User.email == email))).scalar_one()


async def expire_leases(env: Env) -> None:
    async with env.app.state.sessionmaker() as s, s.begin():
        await s.execute(
            update(ExtractionJob).values(lease_expires_at=datetime.now(UTC) - timedelta(minutes=1))
        )


# --- CAP-01: upload intent -----------------------------------------------------------------


@pytest.mark.parametrize(
    "override, status, code",
    [
        ({"owns_rights": False}, 422, "RIGHTS_CONFIRMATION_REQUIRED"),
        ({"content_type": "image/png"}, 415, "VIDEO_TYPE_UNSUPPORTED"),
        ({"content_type": "video/webm"}, 415, "VIDEO_TYPE_UNSUPPORTED"),
        ({"size_bytes": 200 * 1024 * 1024 + 1}, 413, "VIDEO_TOO_LARGE"),
        ({"duration_ms": 15 * 60 * 1000 + 1}, 422, "VIDEO_TOO_LONG"),
    ],
)
async def test_upload_intent_rejects_clearly(
    env: Env, override: dict[str, Any], status: int, code: str
) -> None:
    headers = await bearer(env.client, "creator@example.com")
    res = await env.client.post(
        "/v1/media/upload-intents", json=intent_body(**override), headers=headers
    )
    assert res.status_code == status, res.text
    assert res.json()["error"]["code"] == code
    assert res.json()["error"]["message"]


async def test_upload_intent_requires_explicit_rights_and_auth(env: Env) -> None:
    body = intent_body()
    body.pop("owns_rights")
    headers = await bearer(env.client, "creator@example.com")
    res = await env.client.post("/v1/media/upload-intents", json=body, headers=headers)
    assert res.json()["error"]["code"] == "RIGHTS_CONFIRMATION_REQUIRED"
    res = await env.client.post("/v1/media/upload-intents", json=intent_body())
    assert res.status_code == 401


async def test_upload_intent_is_a_signed_put_with_consent(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    res = await env.client.post(
        "/v1/media/upload-intents",
        json=intent_body(content_type="video/quicktime", size_bytes=4242),
        headers=headers,
    )
    assert res.status_code == 201
    out = res.json()
    assert out["method"] == "PUT"
    assert out["headers"] == {"Content-Type": "video/quicktime", "Content-Length": "4242"}
    assert "X-Amz-Signature=" in out["upload_url"]
    assert "content-length%3Bcontent-type%3Bhost" in out["upload_url"]
    assert out["max_bytes"] == 200 * 1024 * 1024 and out["max_duration_ms"] == 900_000
    key = key_from_url(out["upload_url"], env.storage.bucket)
    assert key.endswith(f"{out['media_id']}.mov") and key.startswith("sources/")
    async with env.app.state.sessionmaker() as s:
        row = await s.get(RecipeMedia, uuid.UUID(out["media_id"]))
        assert row is not None and row.status == "pending" and row.storage_key == key
        consent = await s.get(MediaConsent, row.consent_record_id)
        assert consent is not None and consent.confirmed_rights
        assert consent.consent_type == "own_video_rights"
    # The intent alone doesn't count as an extraction.
    res = await env.client.get("/v1/media?kind=source_video", headers=headers)
    assert [m["status"] for m in res.json()["items"]] == ["pending"]


async def test_mark_uploaded_checks_the_object(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    data = env.video.read_bytes()
    intent = (
        await env.client.post(
            "/v1/media/upload-intents", json=intent_body(size_bytes=len(data)), headers=headers
        )
    ).json()
    path = f"/v1/media/{intent['media_id']}/uploaded"
    res = await env.client.post(path, headers=headers)
    assert res.status_code == 409 and res.json()["error"]["code"] == "UPLOAD_INCOMPLETE"
    await put_object(env, intent["upload_url"], data[:-10])
    res = await env.client.post(path, headers=headers)
    assert res.status_code == 409 and res.json()["error"]["code"] == "UPLOAD_INCOMPLETE"
    await put_object(env, intent["upload_url"], data)
    first = await env.client.post(path, headers=headers)
    assert first.status_code == 202
    again = await env.client.post(path, headers=headers)
    assert again.status_code == 200 and again.json()["id"] == first.json()["id"]
    out = first.json()
    assert out["status"] == "queued" and out["kind"] == "extract" and out["progress"] == 0
    assert out["media_id"] == intent["media_id"] and out["error"] is None
    d = await draft(env, headers, out["draft_id"])
    assert d["extraction"]["job_id"] == out["id"]
    assert d["extraction"]["source_media_id"] == intent["media_id"]


# --- the Slice 5 gate ----------------------------------------------------------------------


async def test_gate_upload_review_publish_play_clips(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    started = await upload(env, headers)
    polled = await job(env, headers, started["id"])
    assert polled["status"] == "queued"
    # The partial draft exists right away and can't be edited or published mid-extraction.
    res = await env.client.patch(
        f"/v1/recipes/drafts/{started['draft_id']}", json={"title": "x"}, headers=headers
    )
    assert res.status_code == 409 and res.json()["error"]["code"] == "STATE_CONFLICT"
    res = await env.client.post(
        f"/v1/recipes/drafts/{started['draft_id']}/publish", headers=headers
    )
    assert res.status_code == 409

    assert await run_all(env.worker()) == 1
    done = await job(env, headers, started["id"])
    assert done["status"] == "ready" and done["progress"] == 100 and done["stage"] == "done"
    assert done["demo"] is True and done["clips_ready"] == 3 and done["clips_failed"] == 0

    d = await draft(env, headers, done["draft_id"])
    assert d["status"] == "draft"
    assert d["extraction"]["demo"] is True and d["extraction"]["notice"].startswith("Demo")
    assert all(i["evidence_origin"] == "ai_extracted" for i in d["ingredients"])
    assert all(s["evidence_origin"] == "ai_extracted" for s in d["steps"])
    butter = next(i for i in d["ingredients"] if i["name"] == "butter")
    assert butter["quantity"] is None and butter["unit"] is None  # unknown stays unknown
    spans = [(s["source_start_ms"], s["source_end_ms"]) for s in d["steps"]]
    assert spans == [(0, 3000), (1000, 5000), (3000, 5000)]  # ±1 s, clamped to 5 s
    clip_ids = [s["source_clip_id"] for s in d["steps"]]
    assert all(clip_ids)

    # Clips are owner-only until published.
    clip = (await env.client.get(f"/v1/media/{clip_ids[0]}", headers=headers)).json()
    assert clip["status"] == "ready" and clip["kind"] == "step_clip" and clip["url"]
    assert clip["published"] is False and clip["mime_type"] == MP4
    assert (await env.client.get(f"/v1/media/{clip_ids[0]}")).status_code == 404

    # The creator corrects an AI field and publishes.
    ingredients = d["ingredients"]
    butter["quantity"], butter["unit"], butter["evidence_origin"] = 2, "tbsp", "creator_reviewed"
    res = await env.client.patch(
        f"/v1/recipes/drafts/{d['id']}",
        json={"title": "Garlic Butter Noodles", "ingredients": ingredients},
        headers=headers,
    )
    assert res.status_code == 200, res.text
    res = await env.client.post(f"/v1/recipes/drafts/{d['id']}/publish", headers=headers)
    assert res.status_code == 201, res.text
    published = res.json()

    detail = (await env.client.get(f"/v1/recipes/{published['recipe_id']}")).json()
    assert [s["source_clip_id"] for s in detail["steps"]] == clip_ids
    assert {s["evidence_origin"] for s in detail["steps"]} == {"creator_reviewed"}
    assert {i["evidence_origin"] for i in detail["ingredients"]} == {"creator_reviewed"}
    assert "extraction" not in detail

    # A cook (anonymous here) plays two or more clips from the published recipe.
    played = 0
    for clip_id in clip_ids:
        res = await env.client.get(f"/v1/media/{clip_id}")
        assert res.status_code == 200
        out = res.json()
        assert out["published"] is True and out["url"] and out["recipe_id"] == detail["recipe_id"]
        row = await media_row(env, clip_id)
        assert row is not None and row.version_id is not None and await exists(env, row.storage_key)
        played += 1
    assert played >= 2

    # The source video is kept after publish (DECISIONS #20), owner-only.
    source = await media_row(env, started["media_id"])
    assert source is not None and await exists(env, source.storage_key)
    assert source.recipe_id is not None and str(source.recipe_id) == published["recipe_id"]
    assert (await env.client.get(f"/v1/media/{started['media_id']}")).status_code == 404
    mine = (await env.client.get("/v1/media?kind=source_video", headers=headers)).json()
    assert [m["id"] for m in mine["items"]] == [started["media_id"]]
    assert mine["items"][0]["url"] is None  # listing never mints URLs


async def test_no_media_bytes_in_the_database(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    await ready_extraction(env, headers)
    async with env.app.state.sessionmaker() as s:
        rows = (await s.execute(select(RecipeMedia))).scalars().all()
        assert rows and all(len(r.storage_key) < 200 for r in rows)
        sizes = await s.execute(text("SELECT max(pg_column_size(t.*)) FROM recipe_media t"))
        assert int(sizes.scalar_one()) < 2000


# --- trim, retention, deletion -------------------------------------------------------------


async def test_trim_rerenders_one_clip(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    _done, d = await ready_extraction(env, headers)
    old_id = d["steps"][0]["source_clip_id"]
    old = await media_row(env, old_id)
    assert old is not None
    path = f"/v1/recipes/drafts/{d['id']}/steps/step-1/trim"

    for body, status in [
        ({"start_ms": 1000, "end_ms": 9000}, 422),  # past the end
        ({"start_ms": 2000, "end_ms": 2000}, 422),
        ({"start_ms": 2000, "end_ms": 2200}, 422),  # under 0.5 s
        ({"start_ms": -1, "end_ms": 2000}, 422),
    ]:
        res = await env.client.post(path, json=body, headers=headers)
        assert res.status_code == status, (body, res.text)
    res = await env.client.post(
        f"/v1/recipes/drafts/{d['id']}/steps/step-404/trim",
        json={"start_ms": 0, "end_ms": 1000},
        headers=headers,
    )
    assert res.status_code == 404

    res = await env.client.post(path, json={"start_ms": 500, "end_ms": 2500}, headers=headers)
    assert res.status_code == 202, res.text
    trim = res.json()
    assert trim["kind"] == "trim" and trim["status"] == "queued" and trim["clip_id"]
    d2 = await draft(env, headers, d["id"])
    step = d2["steps"][0]
    assert step["source_clip_id"] == trim["clip_id"] != old_id
    assert (step["source_start_ms"], step["source_end_ms"]) == (500, 2500)
    assert await media_row(env, old_id) is None  # unpublished old clip discarded

    # Publishing waits for the new clip.
    res = await env.client.post(f"/v1/recipes/drafts/{d['id']}/publish", headers=headers)
    assert res.status_code == 422
    problems = res.json()["error"]["details"]["problems"]
    assert problems == [
        {
            "field": "steps[0].source_clip_id",
            "message": "Step 1's clip is still being made; wait a moment",
        }
    ]

    await run_all(env.worker())
    assert not await exists(env, old.storage_key)  # outbox drained
    done = await job(env, headers, trim["id"])
    assert done["status"] == "ready" and done["progress"] == 100
    new = await media_row(env, trim["clip_id"])
    assert new is not None and new.status == "ready" and await exists(env, new.storage_key)
    assert (new.start_ms, new.end_ms, new.duration_ms) == (500, 2500, 2000)
    res = await env.client.post(f"/v1/recipes/drafts/{d['id']}/publish", headers=headers)
    assert res.status_code == 201, res.text


async def test_failed_trim_blocks_publish_until_fixed(env: Env, monkeypatch) -> None:
    headers = await bearer(env.client, "creator@example.com")
    _done, d = await ready_extraction(env, headers)

    async def broken(*_a: Any, **_k: Any) -> None:
        raise ffmpeg.MediaToolError("boom")

    monkeypatch.setattr(ffmpeg, "render_clip", broken)
    res = await env.client.post(
        f"/v1/recipes/drafts/{d['id']}/steps/step-2/trim",
        json={"start_ms": 1000, "end_ms": 3000},
        headers=headers,
    )
    trim = res.json()
    await run_all(env.worker(worker_max_attempts=1))
    failed = await job(env, headers, trim["id"])
    assert failed["status"] == "failed" and failed["error"]["code"] == "CLIP_RENDER_FAILED"
    res = await env.client.post(f"/v1/recipes/drafts/{d['id']}/publish", headers=headers)
    assert res.status_code == 422
    assert "couldn't be made" in res.json()["error"]["details"]["problems"][0]["message"]


async def test_delete_draft_deletes_unpublished_clips_keeps_source(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    done, d = await ready_extraction(env, headers)
    clips = [await media_row(env, s["source_clip_id"]) for s in d["steps"]]
    assert all(c is not None for c in clips)
    res = await env.client.delete(f"/v1/recipes/drafts/{d['id']}", headers=headers)
    assert res.status_code == 204
    await env.worker().drain_deletions()
    for clip in clips:
        assert clip is not None
        assert await media_row(env, clip.id) is None
        assert not await exists(env, clip.storage_key)
    source = await media_row(env, done["media_id"])
    assert source is not None and source.draft_id is None and await exists(env, source.storage_key)


async def test_delete_source_video(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    started = await upload(env, headers)
    res = await env.client.delete(f"/v1/media/{started['media_id']}", headers=headers)
    assert res.status_code == 409  # still processing
    await run_all(env.worker())
    d = await draft(env, headers, started["draft_id"])
    published = (
        await env.client.post(f"/v1/recipes/drafts/{d['id']}/publish", headers=headers)
    ).json()
    source = await media_row(env, started["media_id"])
    assert source is not None

    res = await env.client.delete(f"/v1/media/{started['media_id']}", headers=headers)
    assert res.status_code == 204
    await env.worker().drain_deletions()
    assert await media_row(env, started["media_id"]) is None
    assert not await exists(env, source.storage_key)
    # Published clips stay playable without their source.
    clip_id = d["steps"][0]["source_clip_id"]
    assert (await env.client.get(f"/v1/media/{clip_id}")).status_code == 200
    # Published clips can't be deleted on their own.
    res = await env.client.delete(f"/v1/media/{clip_id}", headers=headers)
    assert res.status_code == 409
    # A new draft of the recipe can't trim any more (no source).
    edit = await env.client.post(f"/v1/recipes/{published['recipe_id']}/edit", headers=headers)
    assert edit.status_code == 201, edit.text
    res = await env.client.post(
        f"/v1/recipes/drafts/{edit.json()['id']}/steps/step-1/trim",
        json={"start_ms": 0, "end_ms": 1000},
        headers=headers,
    )
    assert res.status_code == 409


async def test_unpublished_clip_can_be_deleted(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    _done, d = await ready_extraction(env, headers)
    clip_id = d["steps"][1]["source_clip_id"]
    assert (await env.client.delete(f"/v1/media/{clip_id}", headers=headers)).status_code == 204
    assert (await env.client.get(f"/v1/media/{clip_id}", headers=headers)).status_code == 404


async def test_private_recipe_clips_are_not_public(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    _done, d = await ready_extraction(env, headers)
    pub = (await env.client.post(f"/v1/recipes/drafts/{d['id']}/publish", headers=headers)).json()
    clip_id = d["steps"][0]["source_clip_id"]
    assert (await env.client.get(f"/v1/media/{clip_id}")).status_code == 200
    res = await env.client.post(f"/v1/recipes/{pub['recipe_id']}/unpublish", headers=headers)
    assert res.status_code == 200
    assert (await env.client.get(f"/v1/media/{clip_id}")).status_code == 404
    assert (await env.client.get(f"/v1/media/{clip_id}", headers=headers)).status_code == 200


# --- ownership -----------------------------------------------------------------------------


async def test_other_users_get_identical_404s(env: Env) -> None:
    owner = await bearer(env.client, "creator@example.com")
    other = await bearer(env.client, "other@example.com")
    _done, d = await ready_extraction(env, owner)
    source_id = d["extraction"]["source_media_id"]
    job_id = d["extraction"]["job_id"]
    missing = str(uuid.uuid4())

    def strip(res: Any) -> tuple[int, str, str]:
        err = res.json()["error"]
        return res.status_code, err["code"], err["message"]

    pairs = [
        ("get", f"/v1/media/{source_id}", f"/v1/media/{missing}", None),
        ("delete", f"/v1/media/{source_id}", f"/v1/media/{missing}", None),
        ("post", f"/v1/media/{source_id}/uploaded", f"/v1/media/{missing}/uploaded", None),
        ("get", f"/v1/extractions/{job_id}", f"/v1/extractions/{missing}", None),
        (
            "post",
            f"/v1/recipes/drafts/{d['id']}/steps/step-1/trim",
            f"/v1/recipes/drafts/{missing}/steps/step-1/trim",
            {"start_ms": 0, "end_ms": 1000},
        ),
    ]
    for method, theirs, nobody, body in pairs:
        kwargs: dict[str, Any] = {"headers": other}
        if body is not None:
            kwargs["json"] = body
        a = await getattr(env.client, method)(theirs, **kwargs)
        b = await getattr(env.client, method)(nobody, **kwargs)
        assert a.status_code == 404, (method, theirs, a.text)
        assert strip(a) == strip(b)
    assert (await env.client.get("/v1/media", headers=other)).json() == {"items": []}
    assert (await env.client.get("/v1/extractions/not-a-uuid", headers=other)).status_code == 404


# --- limits (DECISIONS #19) ----------------------------------------------------------------


async def _add_jobs(env: Env, uid: uuid.UUID, n: int, **values: Any) -> None:
    async with env.app.state.sessionmaker() as s, s.begin():
        for _ in range(n):
            d = RecipeDraft(owner_user_id=uid, structured_draft_json={}, status=DraftStatus.EDITING)
            s.add(d)
            await s.flush()
            s.add(
                ExtractionJob(
                    owner_user_id=uid,
                    draft_id=d.id,
                    kind="extract",
                    status=ExtractionStatus.REVIEW,
                    attempts=1,
                    **values,
                )
            )


async def test_five_extractions_per_user_per_month(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    uid = await user_id(env, "creator@example.com")
    # Jobs that never spent AI money and last month's jobs don't count.
    await _add_jobs(env, uid, 3, counts_toward_limit=False)
    await _add_jobs(env, uid, 3, created_at=datetime.now(UTC) - timedelta(days=40))
    await _add_jobs(env, uid, 4)
    started = await upload(env, headers)  # the 5th
    assert started["status"] == "queued"
    res = await env.client.post("/v1/media/upload-intents", json=intent_body(), headers=headers)
    assert res.status_code == 429
    err = res.json()["error"]
    assert err["code"] == "VIDEO_EXTRACTION_LIMIT" and err["retryable"] is False
    assert err["details"] == {"limit": 5, "used": 5}
    # Another user is unaffected.
    other = await bearer(env.client, "other@example.com")
    res = await env.client.post("/v1/media/upload-intents", json=intent_body(), headers=other)
    assert res.status_code == 201


async def test_limit_is_rechecked_when_the_upload_lands(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    uid = await user_id(env, "creator@example.com")
    data = env.video.read_bytes()
    intent = (
        await env.client.post(
            "/v1/media/upload-intents", json=intent_body(size_bytes=len(data)), headers=headers
        )
    ).json()
    await put_object(env, intent["upload_url"], data)
    await _add_jobs(env, uid, 5)
    res = await env.client.post(f"/v1/media/{intent['media_id']}/uploaded", headers=headers)
    assert res.status_code == 429 and res.json()["error"]["code"] == "VIDEO_EXTRACTION_LIMIT"


async def _spend(env: Env, usd: str, capability: str = "coach") -> None:
    async with env.app.state.sessionmaker() as s, s.begin():
        s.add(
            AIUsage(
                user_id=None,
                capability=capability,
                model="gemini-3.8-flash",
                status="settled",
                reserved_usd=Decimal(usd),
                cost_usd=Decimal(usd),
                created_at=datetime.now(UTC),
            )
        )


async def test_video_extraction_off_at_soft_cap(genv: Env) -> None:
    headers = await bearer(genv.client, "creator@example.com")
    await _spend(genv, "15.01")
    res = await genv.client.post("/v1/media/upload-intents", json=intent_body(), headers=headers)
    assert res.status_code == 503
    assert res.json()["error"]["code"] == "VIDEO_EXTRACTION_DISABLED"
    status = (await genv.client.get("/v1/ai/status", headers=headers)).json()
    assert status["video_extraction_enabled"] is False


async def test_gemini_without_key_refuses_upload(
    settings: Settings, clean_tables: None, s3_storage, test_video, tmp_path
) -> None:  # type: ignore[no-untyped-def]
    gsettings = settings.model_copy(update={"ai_provider": "gemini"})
    async for e in _env(gsettings, s3_storage, test_video, tmp_path):
        headers = await bearer(e.client, "creator@example.com")
        res = await e.client.post("/v1/media/upload-intents", json=intent_body(), headers=headers)
        assert res.status_code == 503
        assert res.json()["error"]["code"] == "PROVIDER_NOT_CONFIGURED"


async def test_video_is_outside_the_user_day_cap(env: Env) -> None:
    await bearer(env.client, "creator@example.com")
    uid = await user_id(env, "creator@example.com")
    guard: CostGuard = env.app.state.cost_guard
    video = await guard.reserve(uid, "video", "gemini-3.8-flash", Decimal("0.40"))
    assert isinstance(video, Reservation)
    coach = await guard.reserve(uid, "coach", "gemini-3.8-flash", Decimal("0.05"))
    assert isinstance(coach, Reservation)
    status = await guard.status(uid)
    assert status.user_day_spent_usd == Decimal("0.05")
    assert status.month_spent_usd == Decimal("0.45")


# --- worker: validation failures -----------------------------------------------------------


async def test_non_video_bytes_fail_cleanly(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    started = await upload(env, headers, b"definitely not a video " * 100)
    await run_all(env.worker())
    out = await job(env, headers, started["id"])
    assert out["status"] == "failed" and out["error"]["code"] == "VIDEO_UNREADABLE"
    d = await draft(env, headers, started["draft_id"])
    assert d["extraction"]["unknowns"][0] == out["error"]["message"]
    res = await env.client.patch(
        f"/v1/recipes/drafts/{d['id']}", json={"title": "By hand"}, headers=headers
    )
    assert res.status_code == 200  # an editable draft
    source = await media_row(env, started["media_id"])
    assert source is not None and source.status == "rejected"
    async with env.app.state.sessionmaker() as s:
        row = await s.get(ExtractionJob, uuid.UUID(started["id"]))
        assert row is not None and row.counts_toward_limit is False


async def test_too_long_video_fails(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    started = await upload(env, headers)
    await run_all(env.worker(video_max_duration_ms=2000))
    out = await job(env, headers, started["id"])
    assert out["error"]["code"] == "VIDEO_TOO_LONG"


async def test_clip_failure_does_not_block_the_text(env: Env, monkeypatch) -> None:
    headers = await bearer(env.client, "creator@example.com")
    real = ffmpeg.render_clip
    calls = 0

    async def flaky(*args: Any, **kwargs: Any) -> None:
        nonlocal calls
        calls += 1
        if calls == 2:
            raise ffmpeg.MediaToolError("boom")
        await real(*args, **kwargs)

    monkeypatch.setattr(ffmpeg, "render_clip", flaky)
    started = await upload(env, headers)
    await run_all(env.worker())
    out = await job(env, headers, started["id"])
    assert out["status"] == "ready" and out["clips_ready"] == 2 and out["clips_failed"] == 1
    d = await draft(env, headers, started["draft_id"])
    assert [bool(s["source_clip_id"]) for s in d["steps"]] == [True, False, True]
    res = await env.client.post(f"/v1/recipes/drafts/{d['id']}/publish", headers=headers)
    assert res.status_code == 201


# --- worker: claim, retry, crash-resume ----------------------------------------------------


async def test_claim_skips_locked_rows(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    first = await upload(env, headers)
    second = await upload(env, headers)
    async with env.app.state.sessionmaker() as s, s.begin():
        # Another worker mid-claim holds the oldest row: we must take the next one, not wait.
        await s.execute(
            select(ExtractionJob)
            .where(ExtractionJob.id == uuid.UUID(first["id"]))
            .with_for_update()
        )
        claimed = await asyncio.wait_for(env.worker().claim(), timeout=5)
        assert claimed is not None and str(claimed.id) == second["id"]


async def test_concurrent_workers_never_share_a_job(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    ids = {(await upload(env, headers))["id"] for _ in range(3)}
    workers = [env.worker() for _ in range(4)]
    claims = await asyncio.gather(*(w.claim() for w in workers))
    got = [str(c.id) for c in claims if c is not None]
    assert sorted(got) == sorted(ids) and len(set(got)) == 3


class CountingProvider(MockAIProvider):
    def __init__(self, fail_first: int = 0, fail_always: bool = False) -> None:
        super().__init__(FIXTURES_DIR)
        self.calls = 0
        self.fail_first = fail_first
        self.fail_always = fail_always

    async def extract(self, request: ExtractionRequest):  # type: ignore[no-untyped-def]
        self.calls += 1
        if self.fail_always or self.calls <= self.fail_first:
            raise ProviderUnavailable("flaky")
        return await super().extract(request)


async def test_transient_error_is_retried(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    started = await upload(env, headers)
    provider = CountingProvider(fail_first=1)
    worker = env.worker(provider)
    assert await worker.run_once()
    out = await job(env, headers, started["id"])
    assert out["status"] == "queued" and out["attempts"] == 1
    await run_all(worker)
    out = await job(env, headers, started["id"])
    assert out["status"] == "ready" and out["attempts"] == 2 and provider.calls == 2


async def test_retries_are_bounded_and_end_editable(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    started = await upload(env, headers)
    await run_all(env.worker(CountingProvider(fail_always=True), worker_max_attempts=2))
    out = await job(env, headers, started["id"])
    assert out["status"] == "failed" and out["error"]["code"] == "JOB_FAILED"
    assert out["attempts"] == 2
    res = await env.client.patch(
        f"/v1/recipes/drafts/{started['draft_id']}", json={"title": "By hand"}, headers=headers
    )
    assert res.status_code == 200


async def test_crash_mid_clips_resumes_without_paying_twice(env: Env, monkeypatch) -> None:
    headers = await bearer(env.client, "creator@example.com")
    started = await upload(env, headers)
    provider = CountingProvider()
    real = ffmpeg.render_clip
    rendered: list[int] = []

    async def crash_on_second(*args: Any, **kwargs: Any) -> None:
        rendered.append(kwargs["start_ms"])
        if len(rendered) == 2:
            raise SystemExit("worker killed")  # not an Exception: nothing handles it
        await real(*args, **kwargs)

    monkeypatch.setattr(ffmpeg, "render_clip", crash_on_second)
    crashed = env.worker(provider)
    with pytest.raises(SystemExit):
        await crashed.run_once()
    out = await job(env, headers, started["id"])
    assert out["status"] == "processing" and out["stage"] == "rendering_clips"
    assert out["clips_ready"] == 1
    # The text draft is already there while the job is mid-flight.
    d = await draft(env, headers, started["draft_id"])
    assert d["ingredients"] and d["extraction"]["demo"] is True

    # Nobody else can take it while the lease is live...
    monkeypatch.setattr(ffmpeg, "render_clip", real)
    successor = env.worker(provider)
    assert await successor.claim() is None
    # ...and once it expires the next worker resumes it.
    await expire_leases(env)
    assert await successor.run_once()
    out = await job(env, headers, started["id"])
    assert out["status"] == "ready" and out["attempts"] == 2
    assert out["clips_ready"] == 3
    assert provider.calls == 1  # the checkpointed extraction was not repeated
    d = await draft(env, headers, started["draft_id"])
    assert all(s["source_clip_id"] for s in d["steps"])
    async with env.app.state.sessionmaker() as s:
        clips = (
            (await s.execute(select(RecipeMedia).where(RecipeMedia.media_kind == "step_clip")))
            .scalars()
            .all()
        )
        assert len(clips) == 3


async def test_crash_looping_job_is_failed_not_retried_forever(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    started = await upload(env, headers)
    async with env.app.state.sessionmaker() as s, s.begin():
        await s.execute(
            update(ExtractionJob).values(
                status=ExtractionStatus.WORKING,
                attempts=3,
                worker_id="dead",
                lease_expires_at=datetime.now(UTC) - timedelta(minutes=5),
            )
        )
    assert await env.worker().claim() is None
    out = await job(env, headers, started["id"])
    assert out["status"] == "failed" and out["error"]["code"] == "JOB_FAILED"
    d = await draft(env, headers, started["draft_id"])
    res = await env.client.patch(
        f"/v1/recipes/drafts/{d['id']}", json={"title": "By hand"}, headers=headers
    )
    assert res.status_code == 200


async def test_draft_deleted_mid_job_stops_cleanly(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    started = await upload(env, headers)

    class DeletingProvider(MockAIProvider):
        async def extract(self, request: ExtractionRequest):  # type: ignore[no-untyped-def]
            res = await env.client.delete(
                f"/v1/recipes/drafts/{started['draft_id']}", headers=headers
            )
            assert res.status_code == 204
            return await super().extract(request)

    assert await env.worker(DeletingProvider(FIXTURES_DIR)).run_once()
    async with env.app.state.sessionmaker() as s:
        assert await s.get(ExtractionJob, uuid.UUID(started["id"])) is None
        clips = (
            await s.execute(select(RecipeMedia).where(RecipeMedia.media_kind == "step_clip"))
        ).all()
        assert clips == []
        left = (await s.execute(select(MediaDeletion))).scalars().all()
        assert left == []
    # The source video is still the creator's to delete.
    assert await media_row(env, started["media_id"]) is not None


# --- Gemini path (recorded fixtures) -------------------------------------------------------


async def test_gemini_extraction_is_metered_and_cleans_up(
    genv: Env, transport: FakeTransport
) -> None:
    headers = await bearer(genv.client, "creator@example.com")
    transport.queue("video_extraction")
    started = await upload(genv, headers)
    await run_all(genv.worker())
    out = await job(genv, headers, started["id"])
    assert out["status"] == "ready" and out["demo"] is False and out["partial"] is False
    d = await draft(genv, headers, started["draft_id"])
    assert d["title"] == "Weeknight Kimchi Fried Rice"
    assert d["extraction"]["demo"] is False and d["extraction"]["notice"] is None
    sesame = next(i for i in d["ingredients"] if i["name"] == "sesame oil")
    assert sesame["quantity"] is None
    assert len(transport.uploaded) == 1 and transport.deleted == ["files/fake-1"]
    assert transport.uploaded[0]["mime_type"] == MP4
    async with genv.app.state.sessionmaker() as s:
        rows = (await s.execute(select(AIUsage))).scalars().all()
        assert [(r.capability, r.status, r.outcome) for r in rows] == [("video", "settled", "ok")]
        assert rows[0].input_tokens == 12000 and rows[0].cost_usd is not None
        assert rows[0].cost_usd < rows[0].reserved_usd
        job_row = await s.get(ExtractionJob, uuid.UUID(started["id"]))
        assert job_row is not None and "gemini_file" not in (job_row.result_json or {})


async def test_gemini_partial_output_gives_partial_draft(
    genv: Env, transport: FakeTransport
) -> None:
    headers = await bearer(genv.client, "creator@example.com")
    transport.queue("video_malformed", "video_partial")
    started = await upload(genv, headers)
    await run_all(genv.worker())
    out = await job(genv, headers, started["id"])
    assert out["status"] == "ready" and out["partial"] is True
    d = await draft(genv, headers, started["draft_id"])
    assert [s["instruction"] for s in d["steps"]] == ["Boil the noodles."]
    assert d["extraction"]["partial"] is True


@pytest.mark.parametrize(
    "script, code",
    [
        (("video_malformed", "video_malformed"), "AI_OUTPUT_INVALID"),
        (("blocked_candidate",), "AI_SAFETY_BLOCKED"),
    ],
)
async def test_gemini_failures_leave_an_editable_draft(
    genv: Env, transport: FakeTransport, script: tuple[str, ...], code: str
) -> None:
    headers = await bearer(genv.client, "creator@example.com")
    transport.queue(*script)
    started = await upload(genv, headers)
    await run_all(genv.worker())
    out = await job(genv, headers, started["id"])
    assert out["status"] == "failed" and out["error"]["code"] == code
    res = await genv.client.patch(
        f"/v1/recipes/drafts/{started['draft_id']}", json={"title": "By hand"}, headers=headers
    )
    assert res.status_code == 200
    assert transport.deleted == ["files/fake-1"]


async def test_gemini_budget_refusal_at_the_worker(genv: Env, transport: FakeTransport) -> None:
    headers = await bearer(genv.client, "creator@example.com")
    await _spend(genv, "14.99")  # under the soft cap when requested...
    started = await upload(genv, headers)
    await run_all(genv.worker())  # ...but the video's ceiling would cross it
    out = await job(genv, headers, started["id"])
    assert out["status"] == "failed" and out["error"]["code"] == "VIDEO_EXTRACTION_DISABLED"
    assert transport.uploaded == [] and transport.calls == []
    async with genv.app.state.sessionmaker() as s:
        row = await s.get(ExtractionJob, uuid.UUID(started["id"]))
        assert row is not None and row.counts_toward_limit is False


async def test_gemini_resume_deletes_stale_file(genv: Env, transport: FakeTransport) -> None:
    headers = await bearer(genv.client, "creator@example.com")
    transport.queue("video_extraction")
    started = await upload(genv, headers)
    async with genv.app.state.sessionmaker() as s, s.begin():
        await s.execute(
            update(ExtractionJob).values(result_json={"gemini_file": "files/left-behind"})
        )
    await run_all(genv.worker())
    assert transport.deleted == ["files/left-behind", "files/fake-1"]
    assert (await job(genv, headers, started["id"]))["status"] == "ready"
