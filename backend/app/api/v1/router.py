from __future__ import annotations

from fastapi import APIRouter

from app.api.v1 import health, me, recipes

router = APIRouter(prefix="/v1")
router.include_router(health.router)
router.include_router(me.router)
router.include_router(recipes.router)
