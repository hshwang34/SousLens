from __future__ import annotations

from fastapi import APIRouter

from app.api.v1 import ai, drafts, health, me, pantry, recipes, sessions, substitutions

router = APIRouter(prefix="/v1")
router.include_router(health.router)
router.include_router(me.router)
router.include_router(drafts.router)  # before recipes: `/recipes/drafts` is not a recipe id
router.include_router(recipes.router)
router.include_router(recipes.versions_router)
router.include_router(pantry.router)
router.include_router(substitutions.router)
router.include_router(sessions.router)
router.include_router(ai.router)
