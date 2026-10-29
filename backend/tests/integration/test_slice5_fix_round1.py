"""Brief 008 fix round 1: the monthly limit survives draft deletion, a lost lease stops all
spending, published clips are never re-pointed across recipes, every deletion path queues its
storage objects, and upload intents are capped and reaped."""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import pytest
from sqlalchemy import select, text, update

from app.ai.providers.base import ExtractionRequest
from app.ai.providers.mock import MockAIProvider
from app.core.config import Settings
from app.db.models import AIUsage, ExtractionJob, MediaDeletion, RecipeMedia
from app.media.storage import S3Storage
from app.workers.extraction import JobLost
from tests.conftest import FIXTURES_DIR, bearer, draft_payload
from tests.gemini_fake import FakeTransport, fake_provider
from tests.integration.test_slice5_video import (
    Env,
    _env,
    draft,
    exists,
    intent_body,
    job,
    media_row,
    put_object,
    ready_extraction,
    run_all,
    upload,
    user_id,
)


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


async def all_keys(env: Env) -> set[str]:
    async with env.app.state.sessionmaker() as s:
        return set((await s.execute(select(RecipeMedia.storage_key))).scalars().all())


async def queued_keys(env: Env) -> set[str]:
    async with env.app.state.sessionmaker() as s:
        return set((await s.execute(select(MediaDeletion.storage_key))).scalars().all())


# --- 1. the monthly limit can't be reset by deleting drafts --------------------------------


async def test_deleting_drafts_never_refunds_extractions(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    first = await upload(env, headers)
    res = await env.client.delete(f"/v1/recipes/drafts/{first['draft_id']}", headers=headers)
    assert res.status_code == 409  # refused while extracting
    await run_all(env.worker())
    for i in range(5):
        if i:
            await upload(env, headers)
            await run_all(env.worker())
    async with env.app.state.sessionmaker() as s:
        jobs = (await s.execute(select(ExtractionJob))).scalars().all()
    for j in jobs:
        res = await env.client.delete(f"/v1/recipes/drafts/{j.draft_id}", headers=headers)
        assert res.status_code == 204
    async with env.app.state.sessionmaker() as s:
        kept = (await s.execute(select(ExtractionJob))).scalars().all()
        assert len(kept) == 5 and all(j.draft_id is None for j in kept)
    res = await env.client.post("/v1/media/upload-intents", json=intent_body(), headers=headers)
    assert res.status_code == 429 and res.json()["error"]["code"] == "VIDEO_EXTRACTION_LIMIT"
    # The job stays readable, with a null draft_id.
    assert (await job(env, headers, first["id"]))["draft_id"] is None


async def test_an_extracted_video_is_never_extracted_again(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    done, d = await ready_extraction(env, headers)
    assert (
        await env.client.delete(f"/v1/recipes/drafts/{d['id']}", headers=headers)
    ).status_code == 204
    res = await env.client.post(f"/v1/media/{done['media_id']}/uploaded", headers=headers)
    assert res.status_code == 200 and res.json()["id"] == done["id"]
    async with env.app.state.sessionmaker() as s:
        assert len((await s.execute(select(ExtractionJob))).scalars().all()) == 1


# --- 2. a lost lease stops all work and all spending ---------------------------------------


async def test_lost_lease_cancels_the_work(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    started = await upload(env, headers)
    entered = asyncio.Event()
    cancelled = asyncio.Event()

    class SlowProvider(MockAIProvider):
        async def extract(self, request: ExtractionRequest):  # type: ignore[no-untyped-def]
            entered.set()
            try:
                await asyncio.sleep(60)
            except asyncio.CancelledError:
                cancelled.set()
                raise
            return await super().extract(request)

    worker = env.worker(SlowProvider(FIXTURES_DIR))
    worker.heartbeat_seconds = 0.05
    task = asyncio.create_task(worker.run_once())
    await asyncio.wait_for(entered.wait(), timeout=10)
    async with env.app.state.sessionmaker() as s, s.begin():  # another worker took it over
        await s.execute(update(ExtractionJob).values(worker_id="someone-else"))
    assert await asyncio.wait_for(task, timeout=10) is True
    assert cancelled.is_set()
    async with env.app.state.sessionmaker() as s:
        row = await s.get(ExtractionJob, uuid.UUID(started["id"]))
        assert row is not None and row.worker_id == "someone-else"
        assert row.status.value == "working" and row.result_json in (None, {})
    d = await draft(env, headers, started["draft_id"])
    assert d["ingredients"] == []  # the abandoned worker wrote nothing


async def test_heartbeat_errors_also_stop_the_work(env: Env, monkeypatch) -> None:
    headers = await bearer(env.client, "creator@example.com")
    await upload(env, headers)
    entered, cancelled = asyncio.Event(), asyncio.Event()

    class SlowProvider(MockAIProvider):
        async def extract(self, request: ExtractionRequest):  # type: ignore[no-untyped-def]
            entered.set()
            try:
                await asyncio.sleep(60)
            except asyncio.CancelledError:
                cancelled.set()
                raise

    worker = env.worker(SlowProvider(FIXTURES_DIR))
    worker.heartbeat_seconds = 0.05
    real = worker._checkpoint

    async def broken(job: Any, *a: Any, **k: Any) -> None:
        if entered.is_set():
            raise OSError("db unreachable")
        await real(job, *a, **k)

    monkeypatch.setattr(worker, "_checkpoint", broken)
    await asyncio.wait_for(worker.run_once(), timeout=10)
    assert cancelled.is_set()


async def test_no_reservation_for_a_job_this_worker_lost(
    genv: Env, transport: FakeTransport
) -> None:
    headers = await bearer(genv.client, "creator@example.com")
    await upload(genv, headers)
    worker = genv.worker()
    claimed = await worker.claim()
    assert claimed is not None
    async with genv.app.state.sessionmaker() as s, s.begin():
        await s.execute(update(ExtractionJob).values(worker_id="someone-else"))
    source = await media_row(genv, claimed.media_id)  # type: ignore[arg-type]
    assert source is not None
    with pytest.raises(JobLost):
        await worker._run_extractor(claimed, genv.video, source, 5000)
    async with genv.app.state.sessionmaker() as s:
        assert (await s.execute(select(AIUsage))).scalars().all() == []
    assert transport.uploaded == [] and transport.calls == []


async def test_lost_after_reserving_never_calls_gemini(
    genv: Env, transport: FakeTransport, monkeypatch
) -> None:
    headers = await bearer(genv.client, "creator@example.com")
    await upload(genv, headers)
    worker = genv.worker()
    claimed = await worker.claim()
    assert claimed is not None
    guard = genv.app.state.cost_guard
    real_reserve = guard.reserve

    async def reserve_then_lose(*a: Any, **k: Any) -> Any:
        out = await real_reserve(*a, **k)
        async with genv.app.state.sessionmaker() as s, s.begin():
            await s.execute(update(ExtractionJob).values(worker_id="someone-else"))
        return out

    monkeypatch.setattr(guard, "reserve", reserve_then_lose)
    source = await media_row(genv, claimed.media_id)  # type: ignore[arg-type]
    with pytest.raises(JobLost):
        await worker._run_extractor(claimed, genv.video, source, 5000)  # type: ignore[arg-type]
    assert transport.uploaded == [] and transport.calls == []
    async with genv.app.state.sessionmaker() as s:
        rows = (await s.execute(select(AIUsage))).scalars().all()
        assert [(r.status, r.outcome, r.cost_usd) for r in rows] == [("settled", "lost", 0)]


# --- 4. published clips are never re-pointed -----------------------------------------------


async def test_clip_from_another_recipe_cannot_be_published_here(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    _done, d = await ready_extraction(env, headers)
    pub = (await env.client.post(f"/v1/recipes/drafts/{d['id']}/publish", headers=headers)).json()
    clip_id = d["steps"][0]["source_clip_id"]
    await env.client.post(f"/v1/recipes/{pub['recipe_id']}/unpublish", headers=headers)
    assert (await env.client.get(f"/v1/media/{clip_id}")).status_code == 404

    payload = draft_payload()
    payload["steps"][0]["source_clip_id"] = clip_id  # type: ignore[index]
    other = (await env.client.post("/v1/recipes/drafts", json=payload, headers=headers)).json()
    res = await env.client.post(f"/v1/recipes/drafts/{other['id']}/publish", headers=headers)
    assert res.status_code == 422
    assert res.json()["error"]["details"]["problems"] == [
        {
            "field": "steps[0].source_clip_id",
            "message": "Step 1's clip belongs to another recipe; remove it",
        }
    ]
    row = await media_row(env, clip_id)
    assert row is not None and str(row.recipe_id) == pub["recipe_id"]
    assert (await env.client.get(f"/v1/media/{clip_id}")).status_code == 404  # no leak

    # A new version of the *same* recipe may keep its published clips, untouched.
    edit = (await env.client.post(f"/v1/recipes/{pub['recipe_id']}/edit", headers=headers)).json()
    res = await env.client.post(f"/v1/recipes/drafts/{edit['id']}/publish", headers=headers)
    assert res.status_code == 201, res.text
    again = await media_row(env, clip_id)
    assert again is not None and again.version_id == row.version_id


async def test_unpublished_clip_of_another_draft_is_refused(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    _done, d = await ready_extraction(env, headers)
    payload = draft_payload()
    payload["steps"][0]["source_clip_id"] = d["steps"][0]["source_clip_id"]  # type: ignore[index]
    other = (await env.client.post("/v1/recipes/drafts", json=payload, headers=headers)).json()
    res = await env.client.post(f"/v1/recipes/drafts/{other['id']}/publish", headers=headers)
    assert res.status_code == 422


# --- 5. every deletion path queues its objects --------------------------------------------


async def test_account_deletion_queues_every_object(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    _done, d = await ready_extraction(env, headers)
    await env.client.post(f"/v1/recipes/drafts/{d['id']}/publish", headers=headers)
    await ready_extraction(env, headers)  # a second, unpublished draft with clips
    keys = await all_keys(env)
    assert len(keys) == 8  # 2 sources + 6 clips
    uid = await user_id(env, "creator@example.com")
    async with env.app.state.sessionmaker() as s, s.begin():
        await s.execute(text("SET LOCAL souslens.unlock_versions = 'on'"))
        await s.execute(text("DELETE FROM users WHERE id = :id"), {"id": uid})
    assert await all_keys(env) == set()
    assert await queued_keys(env) == keys
    await env.worker().drain_deletions()
    for key in keys:
        assert not await exists(env, key)
    assert await queued_keys(env) == set()


async def test_recipe_deletion_queues_its_media(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    _done, d = await ready_extraction(env, headers)
    pub = (await env.client.post(f"/v1/recipes/drafts/{d['id']}/publish", headers=headers)).json()
    keys = await all_keys(env)
    async with env.app.state.sessionmaker() as s, s.begin():
        await s.execute(text("SET LOCAL souslens.unlock_versions = 'on'"))
        await s.execute(text("DELETE FROM recipes WHERE id = :id"), {"id": pub["recipe_id"]})
    assert await queued_keys(env) == keys  # source + clips all belonged to the recipe
    await env.worker().drain_deletions()
    assert all([not await exists(env, k) for k in keys])


async def test_creator_media_delete_is_queued_once(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    done, _d = await ready_extraction(env, headers)
    source = await media_row(env, done["media_id"])
    assert source is not None
    await env.client.delete(f"/v1/media/{done['media_id']}", headers=headers)
    async with env.app.state.sessionmaker() as s:
        rows = (await s.execute(select(MediaDeletion))).scalars().all()
    assert [r.storage_key for r in rows] == [source.storage_key]


# --- 6. upload abuse caps and the reaper ---------------------------------------------------


async def test_pending_uploads_are_capped(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    for _ in range(2):
        res = await env.client.post("/v1/media/upload-intents", json=intent_body(), headers=headers)
        assert res.status_code == 201
    res = await env.client.post("/v1/media/upload-intents", json=intent_body(), headers=headers)
    assert res.status_code == 429 and res.json()["error"]["code"] == "UPLOAD_LIMIT"
    assert res.json()["error"]["details"] == {"pending": 2}


async def test_monthly_upload_bytes_are_capped_and_never_refunded(
    settings: Settings, clean_tables: None, s3_storage: S3Storage, test_video: Path, tmp_path: Path
) -> None:
    capped = settings.model_copy(update={"video_upload_bytes_per_month": 2500})
    async for e in _env(capped, s3_storage, test_video, tmp_path):
        headers = await bearer(e.client, "creator@example.com")
        first = await e.client.post(
            "/v1/media/upload-intents", json=intent_body(size_bytes=2000), headers=headers
        )
        assert first.status_code == 201
        # Deleting the pending upload frees the slot but not the bytes.
        res = await e.client.delete(f"/v1/media/{first.json()['media_id']}", headers=headers)
        assert res.status_code == 204
        res = await e.client.post(
            "/v1/media/upload-intents", json=intent_body(size_bytes=1000), headers=headers
        )
        assert res.status_code == 429 and res.json()["error"]["code"] == "UPLOAD_LIMIT"
        res = await e.client.post(
            "/v1/media/upload-intents", json=intent_body(size_bytes=400), headers=headers
        )
        assert res.status_code == 201


async def test_reaper_deletes_expired_pending_uploads(env: Env) -> None:
    headers = await bearer(env.client, "creator@example.com")
    stale = (
        await env.client.post(
            "/v1/media/upload-intents", json=intent_body(size_bytes=5), headers=headers
        )
    ).json()
    fresh = (
        await env.client.post(
            "/v1/media/upload-intents", json=intent_body(size_bytes=5), headers=headers
        )
    ).json()
    await put_object(
        env, stale["upload_url"], b"12345"
    )  # a PUT that landed but was never confirmed
    async with env.app.state.sessionmaker() as s, s.begin():
        await s.execute(
            update(RecipeMedia)
            .where(RecipeMedia.id == uuid.UUID(stale["media_id"]))
            .values(created_at=datetime.now(UTC) - timedelta(hours=1))
        )
    stale_row = await media_row(env, stale["media_id"])
    assert stale_row is not None
    assert await env.worker().reap_uploads() == 1
    assert await media_row(env, stale["media_id"]) is None
    assert await media_row(env, fresh["media_id"]) is not None
    await env.worker().drain_deletions()
    assert not await exists(env, stale_row.storage_key)
    # A slot opened up.
    res = await env.client.post("/v1/media/upload-intents", json=intent_body(), headers=headers)
    assert res.status_code == 201
