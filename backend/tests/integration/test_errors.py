"""PRD §11 error envelope + correlation id on every response."""

from __future__ import annotations

import pytest
from httpx import ASGITransport, AsyncClient

from app.core.config import Settings
from app.main import create_app

ENVELOPE_KEYS = {"code", "message", "retryable", "correlation_id"}


async def test_incoming_correlation_id_is_echoed(client: AsyncClient) -> None:
    response = await client.get("/v1/health", headers={"X-Correlation-Id": "abc-123"})
    assert response.headers["x-correlation-id"] == "abc-123"


@pytest.mark.parametrize("value", ["abc-123", "req.42_x", "A" * 128, "7"])
async def test_well_formed_incoming_correlation_ids_are_accepted(
    client: AsyncClient, value: str
) -> None:
    response = await client.get("/v1/health", headers={"X-Correlation-Id": value})
    assert response.headers["x-correlation-id"] == value


@pytest.mark.parametrize(
    "value",
    ["", "   ", "A" * 129, "has space", "semi;colon", "x/y", "<script>", "a,b"],
)
async def test_malformed_incoming_correlation_ids_are_replaced(
    client: AsyncClient, value: str
) -> None:
    response = await client.get("/v1/health", headers={"X-Correlation-Id": value})
    echoed = response.headers["x-correlation-id"]
    assert echoed != value
    assert len(echoed) == 32 and all(c in "0123456789abcdef" for c in echoed)


async def test_generated_correlation_id_when_absent(client: AsyncClient) -> None:
    a = await client.get("/v1/health")
    b = await client.get("/v1/health")
    assert a.headers["x-correlation-id"] != b.headers["x-correlation-id"]


async def test_unknown_route_uses_envelope(client: AsyncClient) -> None:
    response = await client.get("/v1/nope", headers={"X-Correlation-Id": "cid-404"})
    assert response.status_code == 404
    body = response.json()["error"]
    assert set(body) == ENVELOPE_KEYS
    assert body["code"] == "NOT_FOUND"
    assert body["correlation_id"] == "cid-404"
    assert response.headers["x-correlation-id"] == "cid-404"


async def test_validation_error_envelope_lists_fields_not_values(client: AsyncClient) -> None:
    response = await client.get("/v1/recipes", params={"limit": 0})
    assert response.status_code == 422
    body = response.json()["error"]
    assert body["code"] == "VALIDATION_ERROR"
    assert body["retryable"] is False
    assert body["fields"] == ["query.limit"]
    assert "0" not in body["message"]


async def test_invalid_json_body_is_validation_error(client: AsyncClient) -> None:
    response = await client.post(
        "/v1/auth/dev-login", content=b"{not json", headers={"content-type": "application/json"}
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"


async def test_unhandled_exception_is_internal_envelope(settings: Settings) -> None:
    app = create_app(settings)

    @app.get("/boom")
    async def boom() -> None:
        raise RuntimeError("secret details")

    transport = ASGITransport(app=app, raise_app_exceptions=False)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/boom", headers={"X-Correlation-Id": "cid-500"})
    assert response.status_code == 500
    body = response.json()["error"]
    assert body["code"] == "INTERNAL"
    assert body["retryable"] is True
    assert body["correlation_id"] == "cid-500"
    assert "secret" not in response.text
    assert response.headers["x-correlation-id"] == "cid-500"
