"""Replay recorded Gemini responses: no network, no key, no spend (brief 007).

Fixtures live in ``tests/fixtures/gemini/<name>.json``, either
``{"response": <GenerateContentResponse wire JSON>}`` or ``{"error": {"code", "message",
"status"}}``, in the exact REST shape the API returns (camelCase, ``usageMetadata``,
``finishReason``, ``promptFeedback``). There was no API key when the first set was made, so it is
hand-authored in that shape; ``GEMINI_RECORD=1 make ai-live-smoke`` writes real recordings to
``tests/fixtures/gemini/recorded/`` to compare against.

A script item may also be an exception instance (raised as is) or ``"hang"`` (never answers, so
the caller's timeout fires).

The Files API (brief 008 video) is faked too: ``upload_file`` returns a ``PROCESSING`` file,
each ``get_file`` pops the next state from ``file_states`` (``ACTIVE`` when empty), and
``delete_file`` records the name in ``deleted``.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

from google.genai import errors, types

from app.ai.providers.gemini import GeminiProvider
from app.core.config import Settings

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "gemini"


def load(name: str) -> dict[str, Any]:
    return json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))


class FakeTransport:
    def __init__(self, *script: object) -> None:
        self.script: list[object] = list(script)
        self.calls: list[dict[str, Any]] = []
        self.file_states: list[str] = []
        self.uploaded: list[dict[str, str]] = []
        self.deleted: list[str] = []
        self.upload_error: BaseException | None = None

    def _file(self, name: str, mime_type: str, state: str) -> types.File:
        return types.File(
            name=name,
            uri=f"https://generativelanguage.googleapis.com/v1beta/{name}",
            mime_type=mime_type,
            state=state,
        )

    async def upload_file(self, *, path: str, mime_type: str) -> types.File:
        if self.upload_error is not None:
            raise self.upload_error
        name = f"files/fake-{len(self.uploaded) + 1}"
        self.uploaded.append({"name": name, "path": path, "mime_type": mime_type})
        return self._file(name, mime_type, "PROCESSING")

    async def get_file(self, *, name: str) -> types.File:
        state = self.file_states.pop(0) if self.file_states else "ACTIVE"
        return self._file(name, "video/mp4", state)

    async def delete_file(self, *, name: str) -> None:
        self.deleted.append(name)

    def queue(self, *script: object) -> None:
        self.script.extend(script)

    async def generate(
        self, *, model: str, contents: list[Any], config: types.GenerateContentConfig
    ) -> types.GenerateContentResponse:
        self.calls.append({"model": model, "contents": contents, "config": config})
        if not self.script:
            raise AssertionError("FakeTransport: no scripted response left")
        item = self.script.pop(0)
        if isinstance(item, BaseException):
            raise item
        if item == "hang":
            await asyncio.sleep(3600)
        data = load(str(item))
        if "error" in data:
            code = int(data["error"]["code"])
            cls = errors.ServerError if code >= 500 else errors.ClientError
            raise cls(code, data)
        return types.GenerateContentResponse.model_validate(data["response"])

    def prompt_text(self, index: int = -1) -> str:
        """Everything textual sent on one call: system instruction + text parts."""
        call = self.calls[index]
        texts = [c for c in call["contents"] if isinstance(c, str)]
        return "\n".join([str(call["config"].system_instruction), *texts])


async def no_sleep(_seconds: float) -> None:
    return None


def fake_provider(settings: Settings, transport: FakeTransport) -> GeminiProvider:
    return GeminiProvider(settings, transport=transport, sleep=no_sleep)
