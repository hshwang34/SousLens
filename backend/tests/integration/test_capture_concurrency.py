"""Brief 014 fix round 1: the interviewer runs with no row lock held, a window is claimed so
concurrent turns never call the AI twice for the same words, and at most one question is ever
open. A failing interviewer backs off instead of being retried on every turn."""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Awaitable, Callable
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient

from app.ai.providers.base import CaptureInterviewRequest, GapDecision
from app.ai.providers.mock import MockAIProvider
from app.core.config import Settings
from app.core.errors import ProviderUnavailable
from app.main import create_app
from tests.conftest import FIXTURES_DIR, bearer
from tests.integration.test_capture_api import BASE, Cap


class HookedInterviewer(MockAIProvider):
    def __init__(self) -> None:
        super().__init__(FIXTURES_DIR)
        self.calls = 0
        self.hook: Callable[[], Awaitable[None]] | None = None
        self.fail = False

    async def decide(self, request: CaptureInterviewRequest) -> GapDecision:
        self.calls += 1
        if self.hook is not None:
            hook, self.hook = self.hook, None
            await asyncio.wait_for(hook(), timeout=10)
        if self.fail:
            raise ProviderUnavailable("down")
        return await super().decide(request)


@pytest.fixture
async def hooked(
    settings: Settings, clean_tables: None
) -> AsyncIterator[tuple[AsyncClient, HookedInterviewer]]:
    app = create_app(settings)
    interviewer = HookedInterviewer()
    app.state.ai_provider = interviewer
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client, interviewer


async def _start(client: AsyncClient) -> Cap:
    headers = await bearer(client, "mum@example.com")
    res = await client.post(BASE, json={"mode": "voice"}, headers=headers)
    assert res.status_code == 201, res.text
    return Cap(client, headers, res.json()["id"])


async def test_decide_runs_without_the_row_lock(hooked: Any) -> None:
    client, interviewer = hooked
    cap = await _start(client)
    await cap.say(50_000, "now we let it simmer", silence=0)

    async def pause_meanwhile() -> None:
        # Would deadlock (and time out) if /turns held the session row lock here.
        await cap.post("/commands", {"command": "pause", "t_ms": 51_000})

    interviewer.hook = pause_meanwhile
    out = await cap.say(52_000, silence=2000)
    assert interviewer.calls == 1
    assert out["ask"] is None  # re-checked under the lock: paused meanwhile, so no question
    assert (await cap.get())["paused"] is True


async def test_concurrent_turns_make_one_decide_call_and_one_question(hooked: Any) -> None:
    client, interviewer = hooked
    cap = await _start(client)
    await cap.say(50_000, "now we let it simmer", silence=0)
    started = asyncio.Event()
    release = asyncio.Event()

    async def hold() -> None:
        started.set()
        await release.wait()

    interviewer.hook = hold
    first = asyncio.create_task(cap.say(52_000, silence=2000))
    await started.wait()
    others = [await cap.say(52_000 + i, silence=2000) for i in range(1, 6)]
    release.set()
    results = [await first, *others]
    assert interviewer.calls == 1
    asks = [r["ask"] for r in results if r["ask"]]
    assert len(asks) == 1
    events = (await cap.get())["events"]
    assert sum(e["kind"] == "question" for e in events) == 1


async def test_failing_interviewer_backs_off(hooked: Any) -> None:
    client, interviewer = hooked
    cap = await _start(client)
    interviewer.fail = True
    await cap.say(50_000, "now we let it simmer", silence=0)
    assert (await cap.say(52_000, silence=2000))["ask"] is None
    await cap.say(53_000, "into the oven", silence=0)
    assert (await cap.say(55_000, silence=2000))["ask"] is None
    assert interviewer.calls == 1  # backing off: no call on the next pause
    interviewer.fail = False
    out = await cap.say(63_000, silence=2000)
    assert interviewer.calls == 2 and out["ask"]["topic_key"] == "oven_temperature"
