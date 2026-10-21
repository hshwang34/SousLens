"""Settings refuse insecure configurations at startup."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from app.core.config import MIN_JWT_SECRET_BYTES, REPO_DIR, Settings

GOOD_SECRET = "x" * MIN_JWT_SECRET_BYTES


def test_jwt_secret_is_required(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("JWT_SECRET", raising=False)
    with pytest.raises(ValidationError, match="jwt_secret"):
        Settings(_env_file=None)


@pytest.mark.parametrize("secret", ["", "short", "ci-only", "x" * (MIN_JWT_SECRET_BYTES - 1)])
def test_short_jwt_secret_is_refused(secret: str) -> None:
    with pytest.raises(ValidationError, match="at least 32 bytes"):
        Settings(_env_file=None, jwt_secret=secret)


def test_secret_length_is_measured_in_bytes_not_characters() -> None:
    # 16 two-byte characters = 32 bytes: accepted; 15 = 30 bytes: refused.
    assert Settings(_env_file=None, jwt_secret="\u00e9" * 16).jwt_secret
    with pytest.raises(ValidationError):
        Settings(_env_file=None, jwt_secret="\u00e9" * 15)


def test_dev_auth_in_prod_is_refused() -> None:
    with pytest.raises(ValidationError, match="AUTH_MODE=dev is forbidden"):
        Settings(_env_file=None, jwt_secret=GOOD_SECRET, environment="prod", auth_mode="dev")


@pytest.mark.parametrize("environment", ["dev", "test"])
def test_dev_auth_allowed_outside_prod(environment: str) -> None:
    settings = Settings(
        _env_file=None, jwt_secret=GOOD_SECRET, environment=environment, auth_mode="dev"
    )
    assert settings.auth_mode == "dev"


def test_prod_with_apple_auth_is_allowed() -> None:
    settings = Settings(
        _env_file=None, jwt_secret=GOOD_SECRET, environment="prod", auth_mode="apple"
    )
    assert settings.environment == "prod"


def test_env_example_placeholder_satisfies_length_rule() -> None:
    line = next(
        line
        for line in (REPO_DIR / ".env.example").read_text().splitlines()
        if line.startswith("JWT_SECRET=")
    )
    assert Settings(_env_file=None, jwt_secret=line.split("=", 1)[1].strip()).jwt_secret
