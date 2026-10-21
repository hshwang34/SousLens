from __future__ import annotations

from httpx import AsyncClient


async def test_health(client: AsyncClient) -> None:
    response = await client.get("/v1/health")
    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "version": "0.1.0",
        "ai_provider": "mock",
    }
    assert response.headers["x-correlation-id"]


async def test_health_rejects_other_methods_with_405_envelope(client: AsyncClient) -> None:
    response = await client.post("/v1/health")
    assert response.status_code == 405
    body = response.json()["error"]
    assert body["code"] == "METHOD_NOT_ALLOWED"
    assert body["retryable"] is False
