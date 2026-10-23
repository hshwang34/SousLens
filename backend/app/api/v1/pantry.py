"""Pantry (PAN-01..05) and pantry observations (brief 004 contract). Owner only."""

from __future__ import annotations

import json
import re
import uuid
from datetime import UTC, datetime

import pydantic
from fastapi import APIRouter, Request, Response, status
from fastapi.exceptions import RequestValidationError

from app.ai.providers.base import AIProvider, PantryObservationRequest
from app.core.errors import NotFound, UnsupportedMediaType, ValidationError
from app.core.security import CurrentUser, SettingsDep
from app.db.engine import DbSession
from app.domains.matching.dictionary import load_dictionary
from app.domains.pantry import observations, service, upload
from app.domains.pantry.schemas import (
    ConfirmBody,
    CreatePantryItems,
    ObservationOut,
    PantryItemOut,
    PantryList,
    PantryPatch,
    TranscriptObservationIn,
)

router = APIRouter(prefix="/pantry", tags=["pantry"])

_FIXTURE_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def _now() -> datetime:
    return datetime.now(UTC)


def _item_id(value: str) -> uuid.UUID:
    try:
        return uuid.UUID(value)
    except ValueError as exc:
        raise NotFound("Pantry item not found") from exc


@router.get("", response_model=PantryList)
async def list_pantry(session: DbSession, user: CurrentUser) -> PantryList:
    rows = await service.list_items(session, user, _now())
    return PantryList(items=[PantryItemOut.of(r) for r in rows])


@router.post("", response_model=PantryList, status_code=status.HTTP_201_CREATED)
async def add_pantry_items(
    body: CreatePantryItems, session: DbSession, user: CurrentUser
) -> PantryList:
    dictionary = await load_dictionary(session)
    rows = await service.create_items(session, user, body, dictionary, _now())
    return PantryList(items=[PantryItemOut.of(r) for r in rows])


_OBSERVATION_BODY = {
    "requestBody": {
        "required": True,
        "content": {
            "application/json": {"schema": TranscriptObservationIn.model_json_schema()},
            "multipart/form-data": {
                "schema": {
                    "type": "object",
                    "required": ["mode", "image"],
                    "properties": {
                        "mode": {"type": "string", "enum": ["photo"]},
                        "image": {"type": "string", "format": "binary"},
                        "fixture": {"type": "string", "description": "AI_PROVIDER=mock only"},
                    },
                }
            },
        },
    }
}


async def _transcript_request(request: Request) -> PantryObservationRequest:
    raw = await upload.read_body_capped(request, limit=64 * 1024)
    try:
        payload = json.loads(raw or b"null")
        body = TranscriptObservationIn.model_validate(payload)
    except json.JSONDecodeError as exc:
        raise ValidationError("Request body is not valid JSON", extra={"fields": ["body"]}) from exc
    except pydantic.ValidationError as exc:
        raise RequestValidationError(exc.errors()) from exc
    return PantryObservationRequest(mode="transcript", transcript=body.transcript)


async def _multipart_request(
    request: Request, content_type: str, *, mock: bool
) -> PantryObservationRequest:
    body = await upload.read_body_capped(request)
    parts = upload.parse_multipart(body, content_type)
    del body
    mode = upload.text_field(parts, "mode")
    if mode == "transcript":
        transcript = upload.text_field(parts, "transcript") or ""
        try:
            parsed = TranscriptObservationIn(mode="transcript", transcript=transcript)
        except pydantic.ValidationError as exc:
            raise RequestValidationError(exc.errors()) from exc
        return PantryObservationRequest(mode="transcript", transcript=parsed.transcript)
    if mode != "photo":
        raise ValidationError("mode must be photo or transcript", extra={"fields": ["mode"]})
    image = parts.get("image")
    if image is None or image.filename is None or not image.data:
        raise ValidationError("photo mode needs an image file", extra={"fields": ["image"]})
    data = bytes(image.data)
    image.data.clear()
    mime = upload.sniff_image(data)
    fixture = upload.text_field(parts, "fixture") if mock else None
    if fixture is not None and not _FIXTURE_RE.fullmatch(fixture):
        raise ValidationError("fixture must be a fixture file stem", extra={"fields": ["fixture"]})
    return PantryObservationRequest(
        mode="photo",
        image_ref=fixture if mock else None,
        image_bytes=data,
        image_mime_type=mime,
    )


@router.post(
    "/observations",
    response_model=ObservationOut,
    status_code=status.HTTP_201_CREATED,
    openapi_extra=_OBSERVATION_BODY,
)
async def create_observation(
    request: Request, session: DbSession, user: CurrentUser, settings: SettingsDep
) -> ObservationOut:
    content_type = request.headers.get("content-type", "")
    media = content_type.split(";", 1)[0].strip().lower()
    mock = settings.ai_provider == "mock"
    if media == "application/json":
        obs_request = await _transcript_request(request)
    elif media == "multipart/form-data":
        obs_request = await _multipart_request(request, content_type, mock=mock)
    else:
        raise UnsupportedMediaType("Send JSON for a transcript or multipart/form-data for a photo")

    provider: AIProvider = request.app.state.ai_provider
    dictionary = await load_dictionary(session)
    try:
        return await observations.create_observation(
            session, user, provider, provider.name, obs_request, dictionary, _now()
        )
    finally:
        # The photo is processed in memory only (PRIV-01); drop our reference straight away.
        obs_request.image_bytes = None


@router.patch("/{item_id}", response_model=PantryItemOut)
async def patch_pantry_item(
    item_id: str, body: PantryPatch, session: DbSession, user: CurrentUser
) -> PantryItemOut:
    dictionary = await load_dictionary(session)
    row = await service.patch_item(session, user, _item_id(item_id), body, dictionary, _now())
    return PantryItemOut.of(row)


@router.post("/{item_id}/confirm", response_model=PantryItemOut)
async def confirm_pantry_item(
    item_id: str, session: DbSession, user: CurrentUser, body: ConfirmBody | None = None
) -> PantryItemOut:
    row = await service.confirm_item(session, user, _item_id(item_id), _now())
    return PantryItemOut.of(row)


@router.delete("/{item_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_pantry_item(item_id: str, session: DbSession, user: CurrentUser) -> Response:
    await service.delete_item(session, user, _item_id(item_id))
    return Response(status_code=status.HTTP_204_NO_CONTENT)
