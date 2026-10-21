from __future__ import annotations

import uuid
import warnings
from datetime import UTC, datetime, timedelta

import jwt
import pytest
from jwt.warnings import InsecureKeyLengthWarning

from app.core.config import Settings
from app.core.errors import Unauthorized
from app.core.security import create_access_token, verify_access_token

SETTINGS = Settings(jwt_secret="unit-test-secret-0123456789abcdefghij", jwt_ttl_days=30)


def _claims(**overrides: object) -> dict[str, object]:
    now = datetime.now(UTC)
    claims: dict[str, object] = {
        "sub": str(uuid.uuid4()),
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(days=1)).timestamp()),
        "iss": SETTINGS.app_name,
    }
    claims.update(overrides)
    return claims


def test_token_round_trip() -> None:
    user_id = uuid.uuid4()
    token = create_access_token(SETTINGS, user_id)
    assert verify_access_token(SETTINGS, token) == user_id


def test_expired_token_is_unauthorized() -> None:
    token = create_access_token(SETTINGS, uuid.uuid4(), now=datetime.now(UTC) - timedelta(days=31))
    with pytest.raises(Unauthorized):
        verify_access_token(SETTINGS, token)


def test_wrong_secret_is_unauthorized() -> None:
    token = create_access_token(SETTINGS, uuid.uuid4())
    with pytest.raises(Unauthorized):
        verify_access_token(Settings(jwt_secret="another-secret-0123456789abcdefghijk"), token)


def test_garbage_token_is_unauthorized() -> None:
    with pytest.raises(Unauthorized):
        verify_access_token(SETTINGS, "not.a.jwt")


def test_token_without_subject_is_unauthorized() -> None:
    now = datetime.now(UTC)
    token = jwt.encode(
        {"iat": int(now.timestamp()), "exp": int((now + timedelta(days=1)).timestamp())},
        SETTINGS.jwt_secret,
        algorithm="HS256",
    )
    with pytest.raises(Unauthorized):
        verify_access_token(SETTINGS, token)


def test_alg_none_token_is_unauthorized() -> None:
    token = jwt.encode(_claims(), key="", algorithm="none")
    with pytest.raises(Unauthorized):
        verify_access_token(SETTINGS, token)


def test_hs512_token_is_unauthorized() -> None:
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", InsecureKeyLengthWarning)
        token = jwt.encode(_claims(), SETTINGS.jwt_secret, algorithm="HS512")
    with pytest.raises(Unauthorized):
        verify_access_token(SETTINGS, token)


def test_tampered_signature_is_unauthorized() -> None:
    token = create_access_token(SETTINGS, uuid.uuid4())
    header, payload, signature = token.split(".")
    flipped = ("A" if signature[0] != "A" else "B") + signature[1:]
    with pytest.raises(Unauthorized):
        verify_access_token(SETTINGS, ".".join([header, payload, flipped]))


def test_tampered_payload_is_unauthorized() -> None:
    token = create_access_token(SETTINGS, uuid.uuid4())
    header, _payload, signature = token.split(".")
    forged = jwt.encode(_claims(), SETTINGS.jwt_secret, algorithm="HS256").split(".")[1]
    with pytest.raises(Unauthorized):
        verify_access_token(SETTINGS, ".".join([header, forged, signature]))


def test_wrong_issuer_is_unauthorized() -> None:
    token = jwt.encode(_claims(iss="someone-else"), SETTINGS.jwt_secret, algorithm="HS256")
    with pytest.raises(Unauthorized):
        verify_access_token(SETTINGS, token)


def test_non_uuid_subject_is_unauthorized() -> None:
    token = jwt.encode(_claims(sub="admin"), SETTINGS.jwt_secret, algorithm="HS256")
    with pytest.raises(Unauthorized):
        verify_access_token(SETTINGS, token)
