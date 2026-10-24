"""Shared helpers for the brief 005 (Slice 3) integration tests."""

from __future__ import annotations

import json
import uuid
from typing import Any

from httpx import AsyncClient, Response
from sqlalchemy.ext.asyncio import AsyncSession

from app.scripts.seed import seed_fixtures
from tests.conftest import FIXTURES_DIR


async def seed(db_session: AsyncSession) -> dict[str, str]:
    """Seed dictionary, substitution rules and the five recipes → ``{slug: version_id}``."""
    results = await seed_fixtures(db_session, FIXTURES_DIR)
    return {r.slug: str(r.version_id) for r in results}


def canon(obj: object) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


async def start_session(
    client: AsyncClient,
    headers: dict[str, str],
    version_id: str,
    adaptations: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    r = await client.post(
        "/v1/sessions",
        json={"recipe_version_id": version_id, "adaptations": adaptations or []},
        headers=headers,
    )
    assert r.status_code == 201, r.text
    return r.json()


async def command(
    client: AsyncClient,
    headers: dict[str, str],
    session: dict[str, Any],
    name: str,
    *,
    key: str | None = None,
    expected_revision: int | None = None,
    user_confirmed: object = True,
    **extra: object,
):
    body: dict[str, Any] = {
        "command": name,
        "expected_revision": session["revision"]
        if expected_revision is None
        else expected_revision,
        "user_confirmed": user_confirmed,
        "client_source": "ios_button",
        **extra,
    }
    return await client.post(
        f"/v1/sessions/{session['id']}/commands",
        json=body,
        headers={**headers, "Idempotency-Key": key or str(uuid.uuid4())},
    )


def ok(response: Response) -> dict[str, Any]:
    assert response.status_code == 200, response.text
    return response.json()


async def suggest(
    client: AsyncClient, headers: dict[str, str], version_id: str, ref: str
) -> dict[str, Any]:
    r = await client.post(
        "/v1/substitutions/suggest",
        json={"recipe_version_id": version_id, "ingredient_ref": ref},
        headers=headers,
    )
    assert r.status_code == 200, r.text
    return r.json()


async def set_prefs(
    client: AsyncClient,
    headers: dict[str, str],
    allergies: list[str] | None = None,
    avoid: list[str] | None = None,
) -> dict[str, Any]:
    r = await client.put(
        "/v1/me/preferences",
        json={"allergies": allergies or [], "avoid": avoid or []},
        headers=headers,
    )
    assert r.status_code == 200, r.text
    return r.json()
