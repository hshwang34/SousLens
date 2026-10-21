"""FastAPI application factory. ``app`` at module level is what uvicorn serves."""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.ai.registry import build_provider
from app.api.v1 import auth as auth_router
from app.api.v1.router import router as v1_router
from app.core.config import Settings, get_settings
from app.core.errors import install_error_handlers
from app.core.logging import CorrelationIdMiddleware, configure_logging
from app.core.security import DevAuthProvider
from app.db.engine import make_engine, make_sessionmaker

log = logging.getLogger("souslens.app")


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    configure_logging(settings.log_level)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        engine = make_engine(settings.database_url, echo=settings.db_echo)
        app.state.engine = engine
        app.state.sessionmaker = make_sessionmaker(engine)
        log.info(
            "startup",
            extra={
                "ai_provider": settings.ai_provider,
                "auth_mode": settings.auth_mode,
                "version": settings.app_version,
            },
        )
        try:
            yield
        finally:
            await engine.dispose()

    app = FastAPI(
        title="SousLens API",
        version=settings.app_version,
        lifespan=lifespan,
        docs_url="/docs" if settings.environment != "prod" else None,
        redoc_url=None,
    )
    app.state.settings = settings
    app.state.ai_provider = build_provider(settings)
    app.state.auth_provider = None

    install_error_handlers(app)
    # CORS is off unless origins are configured; the iOS client does not need it.
    if settings.cors_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=settings.cors_origins,
            allow_methods=["*"],
            allow_headers=["*"],
            expose_headers=["X-Correlation-Id"],
        )
    app.add_middleware(CorrelationIdMiddleware)
    app.include_router(v1_router)
    if settings.auth_mode == "dev":
        # The dev-login route is only mounted in dev mode; outside it the path does not exist.
        app.state.auth_provider = DevAuthProvider()
        app.include_router(auth_router.router, prefix="/v1")
    return app


app = create_app()
