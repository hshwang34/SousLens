"""Brief 014 end to end on the mock provider: the scripted "Mum's Kimchi Jjigae" session
(``fixtures/capture/kimchi_jjigae_session.json``) replayed through the API, the worker's
``capture`` kind, publish, and transcript deletion. Plus the worker's failure paths."""

from __future__ import annotations

import json
import re
import uuid
from collections.abc import AsyncIterator
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from pathlib import Path
from typing import Any

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, func, select, update

from app.ai.budget import CostGuard, Denial, Reservation
from app.core.config import Settings
from app.db.models import CaptureEvent, CaptureRequest, CaptureSession, RecipeDraft, User
from app.domains.capture.privacy import purge_transcript, reap_abandoned
from app.main import create_app
from app.workers.extraction import ExtractionWorker
from tests.conftest import FIXTURES_DIR, bearer
from tests.gemini_fake import FakeTransport, fake_provider
from tests.integration.test_capture_api import BASE, Cap

SCRIPT = json.loads((FIXTURES_DIR / "capture" / "kimchi_jjigae_session.json").read_text())


@dataclass
class Env:
    client: AsyncClient
    app: FastAPI
    settings: Settings
    workdir: Path

    def worker(self, provider: object | None = None) -> ExtractionWorker:
        return ExtractionWorker(
            self.app.state.sessionmaker,
            self.settings,
            storage=self.app.state.storage,
            provider=provider or self.app.state.ai_provider,
            guard=self.app.state.cost_guard,
            worker_id=f"w-{uuid.uuid4().hex[:6]}",
            workdir=self.workdir,
        )

    async def run_jobs(self, provider: object | None = None) -> int:
        worker, n = self.worker(provider), 0
        while (job := await worker.claim()) is not None:
            await worker.process(job)
            n += 1
        return n

    async def count(self, model: Any, session_id: str) -> int:
        async with self.app.state.sessionmaker() as s:
            stmt = (
                select(func.count())
                .select_from(model)
                .where(model.session_id == uuid.UUID(session_id))
            )
            return int(await s.scalar(stmt) or 0)


async def _env(settings: Settings, tmp_path: Path, provider: Any = None) -> AsyncIterator[Env]:
    app = create_app(settings)
    if provider is not None:
        app.state.ai_provider = provider
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield Env(client, app, settings, tmp_path)


@pytest.fixture
async def env(settings: Settings, clean_tables: None, tmp_path: Path) -> AsyncIterator[Env]:
    async for e in _env(settings, tmp_path):
        yield e


async def start(env: Env, **body: Any) -> Cap:
    headers = await bearer(env.client, "mum@example.com")
    res = await env.client.post(BASE, json={"mode": "voice", **body}, headers=headers)
    assert res.status_code == 201, res.text
    return Cap(env.client, headers, res.json()["id"])


async def replay(cap: Cap) -> list[dict[str, Any]]:
    """Drive the scripted session; answer each ask from the script. Returns the asks."""
    asks: list[dict[str, Any]] = []
    for turn in SCRIPT["turns"]:
        body = {
            "segments": [{"t_ms": turn["t_ms"], "text": t} for t in turn["segments"]],
            "silence_ms": turn["silence_ms"],
            "assistant_speaking": turn.get("assistant_speaking", False),
            "t_ms": turn["t_ms"],
        }
        out = await cap.post("/turns", body)
        if out["ask"] is None:
            continue
        asks.append({**out["ask"], "turn": turn})
        plan = SCRIPT["answers"].get(out["ask"]["topic_key"], {})
        await cap.outcome(
            out["ask"]["question_id"],
            plan.get("outcome", SCRIPT["default_outcome"]),
            turn["t_ms"] + 2000,
            plan.get("answer_text"),
        )
    return asks


def _numbers(draft: dict[str, Any]) -> set[float]:
    found = {i["quantity"] for i in draft["ingredients"]}
    found |= {s["estimated_minutes"] for s in draft["steps"]}
    found |= {draft["servings"], draft["prep_minutes"], draft["cook_minutes"]}
    return {n for n in found if n is not None}


async def test_kimchi_jjigae_replay(env: Env) -> None:
    cap = await start(env, title_hint=SCRIPT["title_hint"])
    asks = await replay(cap)

    # Exactly one time question, and only after a pause; never while speech is arriving.
    time_asks = [a for a in asks if a["topic"] == "time"]
    assert len(time_asks) == 1
    assert time_asks[0]["text"] == "How long do you let it simmer?"
    for a in asks:
        assert a["turn"]["segments"] == []
        assert a["turn"]["silence_ms"] >= 1500 and not a["turn"].get("assistant_speaking")
    assert [a["topic_key"] for a in asks] == ["simmer_time", "tofu_quantity"]

    finish = await cap.post("/finish", {"t_ms": SCRIPT["finish_t_ms"]})
    assert 1 <= len(finish["questions"]) <= 3
    assert "simmer_time" not in [q["topic_key"] for q in finish["questions"]]
    for q in finish["questions"]:  # she skips the wrap-up
        await cap.outcome(q["question_id"], "skipped", SCRIPT["finish_t_ms"] + 1000)

    job = await cap.post("/generate", status=202)
    assert await env.run_jobs() == 1
    polled = (await env.client.get(f"/v1/extractions/{job['id']}", headers=cap.headers)).json()
    assert polled["status"] == "ready" and polled["kind"] == "capture" and polled["demo"]
    assert (await cap.get())["status"] == "ready"

    res = await env.client.get(f"/v1/recipes/drafts/{job['draft_id']}", headers=cap.headers)
    draft = res.json()
    assert draft["title"] == "Mum's Kimchi Jjigae"
    by_name = {i["name"]: i for i in draft["ingredients"]}
    assert by_name["tofu"]["quantity"] is None and by_name["tofu"]["unit"] is None
    assert by_name["pork belly"]["quantity"] == 300
    unknowns = draft["extraction"]["unknowns"]
    assert "Amount of tofu not stated" in unknowns
    assert "simple rules" in draft["extraction"]["notice"]
    # No invented numbers: every number in the draft was said out loud.
    assert _numbers(draft) <= {300, 2, 1}
    assert all(s["estimated_minutes"] is None for s in draft["steps"])
    assert draft["servings"] is None
    assert all(i["evidence_origin"] == "ai_extracted" for i in draft["ingredients"])
    assert all(s["evidence_origin"] == "ai_extracted" for s in draft["steps"])
    simmer = next(s for s in draft["steps"] if s["instruction"].startswith("We let it simmer"))
    assert "(Until the kimchi goes soft.)" in simmer["instruction"]
    assert not any(s["instruction"] == "Until the kimchi goes soft." for s in draft["steps"])
    assert "My mum always says never rush the kimchi." in draft["creator_notes"]
    for text in (json.dumps(draft),):
        assert not re.search(r"\b(15|fifteen|20|minutes?)\b", text.lower())

    # The creator fixes what's missing and publishes: the transcript is deleted.
    assert await env.count(CaptureEvent, cap.sid) > 0
    patch = await env.client.patch(
        f"/v1/recipes/drafts/{job['draft_id']}", json={"servings": 4}, headers=cap.headers
    )
    assert patch.status_code == 200, patch.text
    pub = await env.client.post(
        f"/v1/recipes/drafts/{job['draft_id']}/publish", headers=cap.headers
    )
    assert pub.status_code == 201, pub.text
    out = await cap.get()
    assert out["events"] == [] and out["transcript_deleted"] is True
    assert await env.count(CaptureEvent, cap.sid) == 0
    assert await env.count(CaptureRequest, cap.sid) == 0


async def _recorded(env: Env) -> tuple[Cap, dict[str, Any]]:
    cap = await start(env)
    await cap.say(1000, "the tofu goes in, then the onion", silence=0)
    await cap.post("/finish", {})
    return cap, await cap.post("/generate", status=202)


async def test_discarding_the_draft_deletes_the_transcript(env: Env) -> None:
    cap, job = await _recorded(env)
    await env.run_jobs()
    res = await env.client.delete(f"/v1/recipes/drafts/{job['draft_id']}", headers=cap.headers)
    assert res.status_code == 204
    out = await cap.get()
    assert out["transcript_deleted"] and out["events"] == [] and out["draft_id"] is None
    assert await env.count(CaptureEvent, cap.sid) == 0


async def test_worker_capture_kind_with_the_mock(env: Env) -> None:
    cap, job = await _recorded(env)
    assert await env.run_jobs() == 1
    draft = (
        await env.client.get(f"/v1/recipes/drafts/{job['draft_id']}", headers=cap.headers)
    ).json()
    assert [i["name"] for i in draft["ingredients"]] == ["tofu", "onion"]
    assert all(i["quantity"] is None for i in draft["ingredients"])
    assert draft["status"] == "draft"
    # The transcript is kept until the draft is published or discarded.
    assert await env.count(CaptureEvent, cap.sid) > 0


async def test_transcript_purged_while_the_ai_writes(env: Env) -> None:
    """The worker re-checks the recording right before writing the draft."""
    cap, job = await _recorded(env)
    mock = env.app.state.ai_provider

    class Purging:
        async def extract_transcript(self, request: Any) -> Any:
            async with env.app.state.sessionmaker() as s, s.begin():
                await s.execute(
                    update(CaptureSession)
                    .where(CaptureSession.id == uuid.UUID(cap.sid))
                    .values(updated_at=datetime.now(UTC) - timedelta(days=31))
                )
            async with env.app.state.sessionmaker() as s, s.begin():
                # The reaper never touches a session the worker owns ...
                assert await reap_abandoned(s, ttl_days=30) == 0
            async with env.app.state.sessionmaker() as s, s.begin():
                # ... but a purge by another path (e.g. the draft-delete trigger) can still land.
                row = await s.get(CaptureSession, uuid.UUID(cap.sid))
                await purge_transcript(s, row)
            return await mock.extract_transcript(request)

    await env.run_jobs(Purging())
    polled = (await env.client.get(f"/v1/extractions/{job['id']}", headers=cap.headers)).json()
    assert polled["status"] == "failed" and polled["error"]["code"] == "SESSION_DELETED"
    draft = await env.client.get(f"/v1/recipes/drafts/{job['draft_id']}", headers=cap.headers)
    assert draft.status_code == 200 and draft.json()["ingredients"] == []  # editable, empty


async def test_abandoned_transcripts_are_reaped_after_30_days(env: Env) -> None:
    old = await start(env)
    await old.say(1000, "the tofu goes in", silence=0)
    fresh = Cap(env.client, old.headers, (await env.client.post(
        BASE, json={"mode": "voice"}, headers=old.headers)).json()["id"])  # fmt: skip
    await fresh.say(1000, "the onion goes in", silence=0)
    async with env.app.state.sessionmaker() as s, s.begin():
        await s.execute(
            update(CaptureSession)
            .where(CaptureSession.id == uuid.UUID(old.sid))
            .values(updated_at=datetime.now(UTC) - timedelta(days=30, minutes=1))
        )
    await env.worker().reap_uploads()  # the capture reaper runs with the upload reaper
    assert (await old.get())["transcript_deleted"] is True
    assert await env.count(CaptureEvent, old.sid) == 0
    assert (await fresh.get())["transcript_deleted"] is False
    assert await env.count(CaptureEvent, fresh.sid) > 0


async def test_any_draft_delete_purges_the_transcript(env: Env) -> None:
    """Not only the API's discard: a raw delete of the draft row purges too (trigger)."""
    cap, job = await _recorded(env)
    await env.run_jobs()
    async with env.app.state.sessionmaker() as s, s.begin():
        await s.execute(delete(RecipeDraft).where(RecipeDraft.id == uuid.UUID(job["draft_id"])))
    out = await cap.get()
    assert out["transcript_deleted"] is True and out["events"] == []
    assert await env.count(CaptureRequest, cap.sid) == 0


@pytest.fixture
async def genv(settings: Settings, clean_tables: None, tmp_path: Path) -> AsyncIterator[Env]:
    gsettings = settings.model_copy(update={"ai_provider": "gemini"})
    transport = FakeTransport()
    async for e in _env(gsettings, tmp_path, provider=fake_provider(gsettings, transport)):
        e.transport = transport  # type: ignore[attr-defined]
        yield e


async def test_gemini_budget_refusal_keeps_the_recording(
    genv: Env, monkeypatch: pytest.MonkeyPatch
) -> None:
    genv.transport.queue("capture_decide")  # type: ignore[attr-defined]
    cap = await start(genv)
    await cap.say(1000, "the tofu goes in", silence=0)
    await cap.post("/finish", {})
    job = await cap.post("/generate", status=202)

    async def refuse(*_a: Any, **_k: Any) -> Denial:
        return Denial("monthly_cap")

    monkeypatch.setattr(CostGuard, "reserve", refuse)
    await genv.run_jobs()
    polled = (await genv.client.get(f"/v1/extractions/{job['id']}", headers=cap.headers)).json()
    assert polled["status"] == "failed" and polled["error"]["code"] == "AI_RESTING"
    out = await cap.get()
    assert out["status"] == "failed"
    assert any(e["kind"] == "utterance" for e in out["events"])
    monkeypatch.undo()

    # AI is back: generate again on the same draft, now with Gemini.
    genv.transport.queue("capture_draft")  # type: ignore[attr-defined]
    again = await cap.post("/generate", status=202)
    assert again["draft_id"] == job["draft_id"] and again["id"] != job["id"]
    await genv.run_jobs()
    polled = (await genv.client.get(f"/v1/extractions/{again['id']}", headers=cap.headers)).json()
    assert polled["status"] == "ready" and polled["demo"] is False
    assert "<capture_data>" in genv.transport.prompt_text()  # type: ignore[attr-defined]


async def test_capture_draft_is_outside_the_user_day_cap(env: Env) -> None:
    await bearer(env.client, "mum@example.com")
    async with env.app.state.sessionmaker() as s:
        uid = await s.scalar(select(User.id).where(User.email == "mum@example.com"))
    guard: CostGuard = env.app.state.cost_guard
    big = await guard.reserve(uid, "capture_draft", "gemini-3.8-flash", Decimal("0.40"))
    assert isinstance(big, Reservation)
    ask = await guard.reserve(uid, "capture", "gemini-3.8-flash", Decimal("0.05"))
    assert isinstance(ask, Reservation)
    status = await guard.status(uid)
    assert status.user_day_spent_usd == Decimal("0.05")
