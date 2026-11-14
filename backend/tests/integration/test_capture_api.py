"""Brief 014 capture API: ownership 404s, idempotent replays, camera refused, the ask gate
(silence, Umma speaking, pause, stop asking, spacing, the 6-ask cap — all driven by ``t_ms``),
question outcomes, finish with ≤ 3 wrap-up questions, and generate."""

from __future__ import annotations

import itertools
import uuid
from typing import Any

from httpx import AsyncClient

from tests.conftest import bearer

BASE = "/v1/capture/sessions"
_keys = itertools.count()


def key() -> dict[str, str]:
    return {"Idempotency-Key": f"k-{next(_keys)}-{uuid.uuid4().hex[:6]}"}


class Cap:
    def __init__(self, client: AsyncClient, headers: dict[str, str], sid: str) -> None:
        self.client, self.headers, self.sid = client, headers, sid

    async def post(self, path: str, body: Any = None, *, k: dict[str, str] | None = None,
                   status: int = 200) -> Any:  # fmt: skip
        res = await self.client.post(
            f"{BASE}/{self.sid}{path}", json=body, headers={**self.headers, **(k or key())}
        )
        assert res.status_code == status, res.text
        return res.json()

    async def say(self, t_ms: int, *texts: str, silence: int = 2000, speaking: bool = False,
                  now: int | None = None, k: dict[str, str] | None = None) -> Any:  # fmt: skip
        segments = [{"t_ms": t_ms, "text": t, "is_final": True} for t in texts]
        body = {"segments": segments, "silence_ms": silence, "assistant_speaking": speaking}
        if now is not None or not texts:
            body["t_ms"] = now if now is not None else t_ms
        return await self.post("/turns", body, k=k)

    async def outcome(self, qid: str, outcome: str, t_ms: int, answer: str | None = None,
                      status: int = 200) -> Any:  # fmt: skip
        body = {"outcome": outcome, "t_ms": t_ms, "answer_text": answer}
        return await self.post(f"/questions/{qid}", body, status=status)

    async def get(self) -> Any:
        res = await self.client.get(f"{BASE}/{self.sid}", headers=self.headers)
        assert res.status_code == 200, res.text
        return res.json()


async def start(client: AsyncClient, email: str = "mum@example.com", **body: Any) -> Cap:
    headers = await bearer(client, email)
    res = await client.post(BASE, json={"mode": "voice", **body}, headers=headers)
    assert res.status_code == 201, res.text
    return Cap(client, headers, res.json()["id"])


# --- create / modes / ownership ------------------------------------------------------------


async def test_create_voice_session(client: AsyncClient) -> None:
    cap = await start(client, title_hint="Mum's Kimchi Jjigae")
    out = await cap.get()
    assert out["status"] == "recording" and out["mode"] == "voice"
    assert out["events"] == [] and out["pending_question"] is None
    assert out["policy"] == {
        "silence_before_ask_ms": 1500,
        "min_ms_between_live_asks": 45000,
        "max_live_asks": 6,
        "question_ttl_ms": 20000,
        "max_wrapup_questions": 3,
    }


async def test_camera_mode_is_coming_soon(client: AsyncClient) -> None:
    headers = await bearer(client, "mum@example.com")
    res = await client.post(BASE, json={"mode": "camera"}, headers=headers)
    assert res.status_code == 422
    err = res.json()["error"]
    assert err["code"] == "CAPTURE_MODE_UNAVAILABLE" and "coming soon" in err["message"].lower()


async def test_create_is_idempotent(client: AsyncClient) -> None:
    headers = {**await bearer(client, "mum@example.com"), "Idempotency-Key": "create-1"}
    first = await client.post(BASE, json={"mode": "voice"}, headers=headers)
    again = await client.post(BASE, json={"mode": "voice"}, headers=headers)
    assert (first.status_code, again.status_code) == (201, 200)
    assert first.json()["id"] == again.json()["id"]
    other = await client.post(BASE, json={"mode": "voice", "title_hint": "x"}, headers=headers)
    assert other.status_code == 409


async def test_open_sessions_are_capped(client: AsyncClient) -> None:
    headers = await bearer(client, "mum@example.com")
    for _ in range(3):
        assert (await client.post(BASE, json={}, headers=headers)).status_code == 201
    res = await client.post(BASE, json={}, headers=headers)
    assert res.status_code == 429


async def test_other_users_get_identical_404s(client: AsyncClient) -> None:
    cap = await start(client)
    intruder = await bearer(client, "intruder@example.com")
    missing = str(uuid.uuid4())
    for sid in (cap.sid, missing, "not-a-uuid"):
        calls = [
            client.get(f"{BASE}/{sid}", headers=intruder),
            client.delete(f"{BASE}/{sid}", headers=intruder),
            client.post(
                f"{BASE}/{sid}/turns",
                json={"segments": [], "silence_ms": 0},
                headers={**intruder, **key()},
            ),
            client.post(
                f"{BASE}/{sid}/commands", json={"command": "pause"}, headers={**intruder, **key()}
            ),
        ]
        for call in calls:
            res = await call
            assert res.status_code == 404, res.text
            assert res.json()["error"]["message"] == "Capture session not found"
    assert (await cap.get())["status"] == "recording"


async def test_writes_need_an_idempotency_key(client: AsyncClient) -> None:
    cap = await start(client)
    res = await client.post(
        f"{BASE}/{cap.sid}/turns", json={"segments": [], "silence_ms": 0}, headers=cap.headers
    )
    assert res.status_code == 422


async def test_no_audio_fields_are_accepted(client: AsyncClient) -> None:
    cap = await start(client)
    body = {"segments": [], "silence_ms": 0, "audio": "UklGRg=="}
    await cap.post("/turns", body, status=422)


# --- turns + the ask gate ------------------------------------------------------------------


async def test_turns_store_final_segments_and_replay(client: AsyncClient) -> None:
    cap = await start(client)
    k = key()
    body_segments = ("First the pork belly goes in, 300 grams of pork belly",)
    first = await cap.say(1000, *body_segments, silence=0, k=k)
    again = await cap.say(1000, *body_segments, silence=0, k=k)
    assert first == again and first["stored"] == 1
    partial = {"segments": [{"t_ms": 1500, "text": "now the", "is_final": False}],
               "silence_ms": 0}  # fmt: skip
    assert (await cap.post("/turns", partial))["stored"] == 0
    events = (await cap.get())["events"]
    assert [(e["kind"], e["t_ms"]) for e in events] == [("utterance", 1000)]
    await cap.post("/turns", {"segments": [], "silence_ms": 5}, k=k, status=409)


async def test_no_ask_while_speaking_or_before_the_pause(client: AsyncClient) -> None:
    cap = await start(client)
    assert (await cap.say(60_000, "now we let it simmer", silence=0))["ask"] is None
    assert (await cap.say(60_500, silence=1499))["ask"] is None
    assert (await cap.say(61_000, silence=3000, speaking=True))["ask"] is None
    ask = (await cap.say(61_500, silence=1500))["ask"]
    assert ask["text"] == "How long do you let it simmer?"
    assert ask["topic_key"] == "simmer_time" and ask["phase"] == "live"
    assert ask["expires_at_ms"] == 61_500 + 20_000
    out = await cap.get()
    assert out["pending_question"]["question_id"] == ask["question_id"]
    assert out["events"][-1]["kind"] == "question"


async def test_one_question_at_a_time_and_expiry(client: AsyncClient) -> None:
    cap = await start(client)
    ask = (await cap.say(50_000, "into the oven it goes"))["ask"]
    assert ask["topic_key"] == "oven_temperature"
    # Still open: no second question, even after a long pause.
    assert (await cap.say(60_000, "let it simmer", silence=9000))["ask"] is None
    expired = await cap.say(70_000, silence=0)
    assert expired["closed_question_id"] == ask["question_id"]
    out = await cap.get()
    assert out["pending_question"] is None
    assert any(e["kind"] == "marker" and e["text"] == "expired" for e in out["events"])
    # Already expired by the turn: reporting it later gives the same answer, not an error.
    late = await cap.outcome(ask["question_id"], "answered", 71_000, "180")
    assert late["outcome"] == "expired"
    assert not any(e["kind"] == "answer" for e in (await cap.get())["events"])


async def test_late_answer_is_expired_whatever_the_order(client: AsyncClient) -> None:
    cap = await start(client)
    ask = (await cap.say(50_000, "let it simmer"))["ask"]  # expires at 70 000
    late = await cap.outcome(ask["question_id"], "answered", 70_001, "about ten minutes")
    assert late["outcome"] == "expired"
    out = await cap.get()
    assert out["pending_question"] is None
    assert not any(e["kind"] == "answer" for e in out["events"])
    marker = next(e for e in out["events"] if e["text"] == "expired")
    assert marker["t_ms"] == 70_000


async def test_absurd_client_time_is_clamped(client: AsyncClient) -> None:
    cap = await start(client)
    ask = (await cap.say(50_000, "let it simmer"))["ask"]
    await cap.outcome(ask["question_id"], "skipped", 10_000_000)
    events = (await cap.get())["events"]
    assert max(e["t_ms"] for e in events) <= 70_000
    # Spacing still counts from a sane close time: 45 s later a new question may come.
    assert (await cap.say(116_000, "into the oven"))["ask"] is not None


async def test_utterances_sharing_a_t_ms_are_all_heard(client: AsyncClient) -> None:
    cap = await start(client)
    first = (await cap.say(10_000, "then the tofu goes in"))["ask"]
    assert first["topic_key"] == "tofu_quantity"
    await cap.outcome(first["question_id"], "skipped", 11_000)
    await cap.say(10_000, "into the oven it goes", silence=0)  # same t_ms as the tofu line
    second = (await cap.say(60_000, silence=2000))["ask"]
    assert second is not None and second["topic_key"] == "oven_temperature"


async def test_answer_skip_later_and_no_repeat(client: AsyncClient) -> None:
    cap = await start(client)
    ask = (await cap.say(50_000, "now we let it simmer"))["ask"]
    out = await cap.outcome(ask["question_id"], "answered", 55_000, "until the kimchi is soft")
    assert out == {"question_id": ask["question_id"], "topic_key": "simmer_time",
                   "outcome": "answered"}  # fmt: skip
    # Same topic again, well after the spacing: never asked twice.
    assert (await cap.say(200_000, "let it simmer some more"))["ask"] is None
    ask2 = (await cap.say(300_000, "the tofu goes in"))["ask"]
    assert ask2["topic_key"] == "tofu_quantity"
    await cap.outcome(ask2["question_id"], "later", 302_000)
    ask3 = (await cap.say(400_000, "into the oven"))["ask"]
    await cap.outcome(ask3["question_id"], "skipped", 401_000)
    events = (await cap.get())["events"]
    answer = next(e for e in events if e["kind"] == "answer")
    assert answer["text"] == "until the kimchi is soft"
    assert answer["question_id"] == ask["question_id"]
    assert any(e["kind"] == "skip" and e["question_id"] == ask3["question_id"] for e in events)
    await cap.outcome(str(uuid.uuid4()), "skipped", 1, status=404)
    await cap.outcome("nope", "skipped", 1, status=404)


async def test_answered_needs_text(client: AsyncClient) -> None:
    cap = await start(client)
    ask = (await cap.say(50_000, "let it simmer"))["ask"]
    await cap.outcome(ask["question_id"], "answered", 51_000, None, status=422)


async def test_spoken_skip_and_stop_asking(client: AsyncClient) -> None:
    cap = await start(client)
    ask = (await cap.say(50_000, "let it simmer"))["ask"]
    out = await cap.say(52_000, "skip", silence=0)
    assert out["closed_question_id"] == ask["question_id"]
    stop = await cap.say(53_000, "okay, stop asking", silence=0)
    assert stop["asking_stopped"] is True
    assert (await cap.say(500_000, "into the oven"))["ask"] is None
    assert (await cap.get())["asking_stopped"] is True


async def test_pause_resume_and_stop_commands(client: AsyncClient) -> None:
    cap = await start(client)
    paused = await cap.post("/commands", {"command": "pause", "t_ms": 1000})
    assert paused["paused"] is True and paused["events"] is None
    assert (await cap.say(50_000, "let it simmer"))["ask"] is None
    await cap.post("/commands", {"command": "resume", "t_ms": 51_000})
    assert (await cap.say(52_000, silence=2000))["ask"] is not None
    stopped = await cap.post("/commands", {"command": "stop_asking"})
    assert stopped["asking_stopped"] is True
    await cap.post("/commands", {"command": "shout"}, status=422)


async def test_spacing_and_cap_follow_t_ms(client: AsyncClient) -> None:
    cap = await start(client)
    foods = ["tofu", "onion", "garlic", "gochugaru", "sugar", "ginger", "rice", "carrot"]
    asked: list[int] = []
    t = 10_000
    for food in foods:
        ask = (await cap.say(t, f"then the {food} goes in"))["ask"]
        if ask:
            asked.append(t)
            await cap.outcome(ask["question_id"], "skipped", t + 1000)
            # 44 s after the close: still too soon.
            assert (await cap.say(t + 45_000, f"more {food}"))["ask"] is None
        t += 46_001 + 1000
    assert len(asked) == 6
    assert all(b - a >= 45_000 for a, b in itertools.pairwise(asked))
    assert (await cap.get())["live_asks_used"] == 6


async def test_delete_session_removes_its_events(client: AsyncClient) -> None:
    cap = await start(client)
    await cap.say(1000, "the tofu goes in", silence=0)
    res = await client.delete(f"{BASE}/{cap.sid}", headers=cap.headers)
    assert res.status_code == 204
    assert (await client.get(f"{BASE}/{cap.sid}", headers=cap.headers)).status_code == 404
