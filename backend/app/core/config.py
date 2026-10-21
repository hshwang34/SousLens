"""Application settings: environment variables first, then backend/.env (PRD §9.1).

Model names and provider keys are pinned here from the environment, never in business code.
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

    auth_mode: Literal["dev", "apple"] = "dev"
    ai_provider: Literal["mock", "gemini"] = "mock"

    gemini_api_key: str | None = None
    gemini_model_structured: str | None = None
    gemini_model_live: str | None = None

    media_root: Path = BACKEND_DIR / "media"
    ffmpeg_path: str = "ffmpeg"
    ffprobe_path: str = "ffprobe"

    fixtures_dir: Path = REPO_DIR / "fixtures"

    cors_origins: list[str] = Field(default_factory=list)

    @model_validator(mode="after")
    def _refuse_insecure_configuration(self) -> Settings:
        if len(self.jwt_secret.encode("utf-8")) < MIN_JWT_SECRET_BYTES:
            raise ValueError(
                f"JWT_SECRET must be at least {MIN_JWT_SECRET_BYTES} bytes (RFC 7518 §3.2)"
            )
        if self.environment == "prod" and self.auth_mode == "dev":
            raise ValueError("AUTH_MODE=dev is forbidden when ENVIRONMENT=prod")
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()
