"""Structured JSON logging with a per-request correlation id.

The middleware logs method, path, status and duration only. Request and response bodies are
never logged (PRD §13.3, §16.2).

One deliberate exception: the ``souslens.devlogin`` logger (``app/domains/users/dev_login.py``)
emits the tester's email and one-time sign-in code at INFO. That logger only runs when
``AUTH_MODE=dev`` (dev/test environments, DECISIONS #5): the server log *is* the delivery
channel for the code, which is what makes dev sign-in a proof of possession rather than
"anyone on the LAN who knows an email". No other logger may include PII.
"""

from __future__ import annotations

import json
import logging
import re
import sys
import time
import uuid
from contextvars import ContextVar
from datetime import UTC, datetime
from typing import Any

from starlette.types import ASGIApp, Message, Receive, Scope, Send

CORRELATION_HEADER = "X-Correlation-Id"
CORRELATION_ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,128}$")

_correlation_id: ContextVar[str | None] = ContextVar("correlation_id", default=None)

_STANDARD_ATTRS = set(logging.LogRecord("", 0, "", 0, "", (), None).__dict__) | {
    "message",
    "asctime",
    "taskName",
}


def get_correlation_id() -> str:
    """Current request's correlation id, or a fresh one when called outside a request."""
    value = _correlation_id.get()
    if value is None:
        value = uuid.uuid4().hex
        _correlation_id.set(value)
    return value


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "ts": datetime.fromtimestamp(record.created, tz=UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "correlation_id": _correlation_id.get(),
        }
        for key, value in record.__dict__.items():
            if key not in _STANDARD_ATTRS and not key.startswith("_"):
                payload[key] = value
        if record.exc_info:
            payload["exc_info"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


def configure_logging(level: str = "INFO") -> None:
    root = logging.getLogger()
    root.setLevel(level.upper())
    # Replace only our own handler; foreign handlers (pytest's caplog, uvicorn) stay attached.
    for handler in list(root.handlers):
        if getattr(handler, "_souslens_json", False):
            root.removeHandler(handler)
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    handler._souslens_json = True  # type: ignore[attr-defined]
    root.addHandler(handler)
    for noisy in ("uvicorn.access",):
        logging.getLogger(noisy).disabled = True


class CorrelationIdMiddleware:
    """Pure ASGI middleware: binds a correlation id, echoes it, logs one line per request."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app
        self.log = logging.getLogger("souslens.request")

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        incoming = next(
            (v.decode("latin-1") for k, v in scope.get("headers", []) if k == b"x-correlation-id"),
            None,
        )
        correlation_id = (
            incoming
            if incoming is not None and CORRELATION_ID_PATTERN.fullmatch(incoming)
            else uuid.uuid4().hex
        )
        token = _correlation_id.set(correlation_id)
        scope.setdefault("state", {})["correlation_id"] = correlation_id
        started = time.perf_counter()
        status_holder = {"status": 0}

        async def send_with_header(message: Message) -> None:
            if message["type"] == "http.response.start":
                status_holder["status"] = message["status"]
                headers = [
                    (k, v)
                    for k, v in message.get("headers", [])
                    if k.lower() != CORRELATION_HEADER.lower().encode()
                ]
                headers.append((CORRELATION_HEADER.lower().encode(), correlation_id.encode()))
                message["headers"] = headers
            await send(message)

        try:
            await self.app(scope, receive, send_with_header)
        finally:
            duration_ms = round((time.perf_counter() - started) * 1000, 2)
            self.log.info(
                "request",
                extra={
                    "method": scope.get("method"),
                    "path": scope.get("path"),
                    "status": status_holder["status"],
                    "duration_ms": duration_ms,
                },
            )
            _correlation_id.reset(token)
