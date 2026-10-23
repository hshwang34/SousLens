"""Typed application errors and the PRD §11 error envelope.

Every error response is ``{"error": {"code", "message", "retryable", "correlation_id"}}`` and
carries ``X-Correlation-Id``. Handlers never echo request bodies.
"""

from __future__ import annotations

import logging
from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.core.logging import CORRELATION_HEADER, get_correlation_id

log = logging.getLogger("souslens.errors")


class AppError(Exception):
    """Base for all errors rendered through the envelope."""

    code: str = "INTERNAL"
    status_code: int = 500
    retryable: bool = False

    def __init__(self, message: str | None = None, *, extra: dict[str, Any] | None = None) -> None:
        self.message = message or self.code.replace("_", " ").capitalize()
        self.extra = extra or {}
        super().__init__(self.message)


class Unauthorized(AppError):
    code = "UNAUTHORIZED"
    status_code = 401


class Forbidden(AppError):
    code = "FORBIDDEN"
    status_code = 403


class NotFound(AppError):
    code = "NOT_FOUND"
    status_code = 404


class ValidationError(AppError):
    code = "VALIDATION_ERROR"
    status_code = 422


class StateConflict(AppError):
    code = "STATE_CONFLICT"
    status_code = 409


class RateLimited(AppError):
    code = "RATE_LIMITED"
    status_code = 429
    retryable = True


class ConfirmationRequired(AppError):
    code = "CONFIRMATION_REQUIRED"
    status_code = 422


class ProviderNotConfigured(AppError):
    code = "PROVIDER_NOT_CONFIGURED"
    status_code = 503
    retryable = False


class DuplicatePantryItem(AppError):
    """PAN-04: a new pantry item matches an existing one and carries no resolution."""

    code = "DUPLICATE_PANTRY_ITEM"
    status_code = 409


class PayloadTooLarge(AppError):
    code = "PAYLOAD_TOO_LARGE"
    status_code = 413


class UnsupportedMediaType(AppError):
    code = "UNSUPPORTED_MEDIA_TYPE"
    status_code = 415


class ProviderOutputInvalid(AppError):
    """The AI provider returned output that failed its schema twice (retry once, then this)."""

    code = "AI_OUTPUT_INVALID"
    status_code = 502
    retryable = True


class ProviderUnavailable(AppError):
    """The AI provider call failed (timeout, 5xx, network): nothing was produced."""

    code = "PROVIDER_UNAVAILABLE"
    status_code = 503
    retryable = True


class Internal(AppError):
    code = "INTERNAL"
    status_code = 500
    retryable = True


def envelope(
    request: Request | None,
    *,
    code: str,
    message: str,
    retryable: bool,
    status_code: int,
    extra: dict[str, Any] | None = None,
) -> JSONResponse:
    correlation_id = (
        getattr(request.state, "correlation_id", None) if request is not None else None
    ) or get_correlation_id()
    body: dict[str, Any] = {
        "error": {
            "code": code,
            "message": message,
            "retryable": retryable,
            "correlation_id": correlation_id,
        }
    }
    if extra:
        body["error"].update(extra)
    return JSONResponse(
        status_code=status_code, content=body, headers={CORRELATION_HEADER: correlation_id}
    )


_HTTP_STATUS_CODES: dict[int, str] = {
    401: "UNAUTHORIZED",
    403: "FORBIDDEN",
    404: "NOT_FOUND",
    405: "METHOD_NOT_ALLOWED",
    409: "STATE_CONFLICT",
    422: "VALIDATION_ERROR",
}


async def _app_error_handler(request: Request, exc: Exception) -> JSONResponse:
    assert isinstance(exc, AppError)
    return envelope(
        request,
        code=exc.code,
        message=exc.message,
        retryable=exc.retryable,
        status_code=exc.status_code,
        extra=exc.extra,
    )


async def _validation_handler(request: Request, exc: Exception) -> JSONResponse:
    assert isinstance(exc, RequestValidationError)
    # Field locations only; never the submitted values.
    fields = sorted({".".join(str(p) for p in err.get("loc", ())) for err in exc.errors()})
    return envelope(
        request,
        code="VALIDATION_ERROR",
        message="Request validation failed",
        retryable=False,
        status_code=422,
        extra={"fields": fields},
    )


async def _http_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    assert isinstance(exc, StarletteHTTPException)
    fallback = "INTERNAL" if exc.status_code >= 500 else "ERROR"
    code = _HTTP_STATUS_CODES.get(exc.status_code, fallback)
    message = exc.detail if isinstance(exc.detail, str) else code.replace("_", " ").capitalize()
    return envelope(
        request,
        code=code,
        message=message,
        retryable=exc.status_code >= 500,
        status_code=exc.status_code,
    )


async def _unhandled_handler(request: Request, exc: Exception) -> JSONResponse:
    log.exception("unhandled error", extra={"error_type": type(exc).__name__})
    return envelope(
        request, code="INTERNAL", message="Internal server error", retryable=True, status_code=500
    )


def install_error_handlers(app: FastAPI) -> None:
    app.add_exception_handler(AppError, _app_error_handler)
    app.add_exception_handler(RequestValidationError, _validation_handler)
    app.add_exception_handler(StarletteHTTPException, _http_exception_handler)
    app.add_exception_handler(Exception, _unhandled_handler)
