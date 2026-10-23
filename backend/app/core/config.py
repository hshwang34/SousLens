"""Application settings: environment variables first, then backend/.env (PRD §9.1).

Model names and provider keys are pinned here from the environment, never in business code.

Fail-closed rules (enforced by the validator below, the process refuses to start otherwise):

* ``JWT_SECRET`` is required and must be at least 32 bytes.
* ``AUTH_MODE`` is required (no default). ``dev`` is only allowed when ``ENVIRONMENT`` is ``dev``
  or ``test``. **Production deploys must set ``ENVIRONMENT=prod`` and ``AUTH_MODE=apple``.**
  ``ENVIRONMENT`` defaults to ``dev`` because an unset value means a local checkout.
* ``DEV_LOGIN_ECHO_CODE`` (returns the sign-in code in the API response) is only allowed when
  ``ENVIRONMENT=test``; it exists so integration tests can drive the two-step dev login.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

BACKEND_DIR = Path(__file__).resolve().parents[2]
REPO_DIR = BACKEND_DIR.parent

APP_VERSION = "0.1.0"
MIN_JWT_SECRET_BYTES = 32


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=BACKEND_DIR / ".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    app_name: str = "souslens"
    app_version: str = APP_VERSION
    environment: Literal["dev", "test", "prod"] = "dev"
    log_level: str = "INFO"

    database_url: str = "postgresql+asyncpg://souslens:souslens@localhost:5433/souslens"
    test_database_url: str = "postgresql+asyncpg://souslens:souslens@localhost:5433/souslens_test"
    db_echo: bool = False

    jwt_secret: str
    jwt_algorithm: Literal["HS256"] = "HS256"
    jwt_ttl_days: int = 30

    auth_mode: Literal["dev", "apple"]
    dev_login_echo_code: bool = False
    # Brute-force budget for the dev sign-in code (per email, across challenges).
    dev_login_cooldown_seconds: int = 30
    dev_login_lockout_window_minutes: int = 15
    dev_login_max_failures_per_window: int = 10
    ai_provider: Literal["mock", "gemini"] = "mock"

    gemini_api_key: str | None = None
    gemini_model_structured: str | None = None
    gemini_model_live: str | None = None

    media_root: Path = BACKEND_DIR / "media"
    ffmpeg_path: str = "ffmpeg"
    ffprobe_path: str = "ffprobe"

    fixtures_dir: Path = REPO_DIR / "fixtures"

    # Public share link base (brief 003): share_url = f"{share_url_base}/{recipe_id}".
    # The domain is not live yet; the iOS app also accepts souslens://recipe/{recipe_id}.
    share_url_base: str = "https://souslens.app/r"

    cors_origins: list[str] = Field(default_factory=list)

    @model_validator(mode="after")
    def _refuse_insecure_configuration(self) -> Settings:
        if len(self.jwt_secret.encode("utf-8")) < MIN_JWT_SECRET_BYTES:
            raise ValueError(
                f"JWT_SECRET must be at least {MIN_JWT_SECRET_BYTES} bytes (RFC 7518 §3.2)"
            )
        if self.jwt_secret.lower().startswith("change-me"):
            raise ValueError(
                "JWT_SECRET is the .env.example placeholder; run `make env` to generate one"
            )
        if self.auth_mode == "dev" and self.environment not in ("dev", "test"):
            raise ValueError("AUTH_MODE=dev is only allowed when ENVIRONMENT is dev or test")
        if self.dev_login_echo_code and self.environment != "test":
            raise ValueError("DEV_LOGIN_ECHO_CODE=true is only allowed when ENVIRONMENT=test")
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()
