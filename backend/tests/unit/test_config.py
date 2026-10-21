"""Settings refuse insecure configurations at startup (fail closed)."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from app.core.config import MIN_JWT_SECRET_BYTES, REPO_DIR, Settings

GOOD_SECRET = "x" * MIN_JWT_SECRET_BYTES


@pytest.fixture(autouse=True)
def _no_ambient_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for key in ("JWT_SECRET", "AUTH_MODE", "ENVIRONMENT", "DEV_LOGIN_ECHO_CODE"):
        monkeypatch.delenv(key, raising=False)


def test_jwt_secret_is_required() -> None:
    with pytest.raises(ValidationError, match="jwt_secret"):
        Settings(_env_file=None, auth_mode="dev")


def test_auth_mode_is_required() -> None:
    with pytest.raises(ValidationError, match="auth_mode"):
        Settings(_env_file=None, jwt_secret=GOOD_SECRET)


@pytest.mark.parametrize("secret", ["", "short", "ci-only", "x" * (MIN_JWT_SECRET_BYTES - 1)])
def test_short_jwt_secret_is_refused(secret: str) -> None:
    with pytest.raises(ValidationError, match="at least 32 bytes"):
        Settings(_env_file=None, jwt_secret=secret, auth_mode="dev")


def test_secret_length_is_measured_in_bytes_not_characters() -> None:
    # 16 two-byte characters = 32 bytes: accepted; 15 = 30 bytes: refused.
    assert Settings(_env_file=None, jwt_secret="\u00e9" * 16, auth_mode="dev").jwt_secret
    with pytest.raises(ValidationError):
        Settings(_env_file=None, jwt_secret="\u00e9" * 15, auth_mode="dev")


def test_dev_auth_in_prod_is_refused() -> None:
    with pytest.raises(ValidationError, match="AUTH_MODE=dev is only allowed"):
        Settings(_env_file=None, jwt_secret=GOOD_SECRET, environment="prod", auth_mode="dev")


@pytest.mark.parametrize("environment", ["dev", "test"])
def test_dev_auth_allowed_in_dev_and_test(environment: str) -> None:
    settings = Settings(
        _env_file=None, jwt_secret=GOOD_SECRET, environment=environment, auth_mode="dev"
    )
    assert settings.auth_mode == "dev"


def test_prod_with_apple_auth_is_allowed() -> None:
    settings = Settings(
        _env_file=None, jwt_secret=GOOD_SECRET, environment="prod", auth_mode="apple"
    )
    assert settings.environment == "prod"


@pytest.mark.parametrize("environment", ["dev", "prod"])
def test_echo_code_refused_outside_test_environment(environment: str) -> None:
    with pytest.raises(ValidationError, match="DEV_LOGIN_ECHO_CODE"):
        Settings(
            _env_file=None,
            jwt_secret=GOOD_SECRET,
            environment=environment,
            auth_mode="apple",
            dev_login_echo_code=True,
        )


def test_echo_code_allowed_in_test_environment() -> None:
    settings = Settings(
        _env_file=None,
        jwt_secret=GOOD_SECRET,
        environment="test",
        auth_mode="dev",
        dev_login_echo_code=True,
    )
    assert settings.dev_login_echo_code is True


def test_echo_code_defaults_off() -> None:
    assert not Settings(_env_file=None, jwt_secret=GOOD_SECRET, auth_mode="dev").dev_login_echo_code


def test_env_example_sets_auth_mode_and_a_long_enough_secret() -> None:
    values = dict(
        line.split("#", 1)[0].strip().split("=", 1)
        for line in (REPO_DIR / ".env.example").read_text().splitlines()
        if "=" in line and not line.startswith("#")
    )
    assert values["AUTH_MODE"] == "dev"
    # The committed placeholder is long enough but is refused *as a placeholder*, so copying
    # .env.example verbatim never yields a working (and therefore shared) secret.
    with pytest.raises(ValidationError, match="placeholder"):
        Settings(_env_file=None, jwt_secret=values["JWT_SECRET"], auth_mode="dev")


def test_ci_workflow_sets_auth_mode_and_secret() -> None:
    workflow = (REPO_DIR / ".github" / "workflows" / "backend.yml").read_text()
    assert "AUTH_MODE: dev" in workflow
    secret = next(
        line.split(":", 1)[1].strip() for line in workflow.splitlines() if "JWT_SECRET:" in line
    )
    assert Settings(_env_file=None, jwt_secret=secret, auth_mode="dev")


def test_placeholder_secret_is_refused() -> None:
    with pytest.raises(ValidationError):
        Settings(jwt_secret="change-me-dev-only-32-bytes-minimum-please", auth_mode="dev")
