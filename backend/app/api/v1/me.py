from __future__ import annotations

from fastapi import APIRouter

from app.core.security import CurrentUser
from app.db.engine import DbSession
from app.domains.matching.dictionary import load_dictionary
from app.domains.recipes import service as recipes_service
from app.domains.recipes.schemas import MyRecipeList, RecipeCardList
from app.domains.users import preferences
from app.domains.users.preferences import PreferencesIn, PreferencesOut
from app.domains.users.schemas import UserOut

router = APIRouter(tags=["me"])


@router.get("/me", response_model=UserOut)
async def me(user: CurrentUser) -> UserOut:
    return UserOut.from_model(user)


@router.get("/me/saved", response_model=RecipeCardList)
async def my_saved(session: DbSession, user: CurrentUser) -> RecipeCardList:
    """Saved recipes, newest save first (REC-02)."""
    return RecipeCardList(items=await recipes_service.list_saved(session, user))


@router.get("/me/recipes", response_model=MyRecipeList)
async def my_recipes(session: DbSession, user: CurrentUser) -> MyRecipeList:
    """Recipes I published (any visibility) with whether an edit draft is open."""
    return MyRecipeList(items=await recipes_service.list_mine(session, user))


@router.get("/me/preferences", response_model=PreferencesOut)
async def get_preferences(session: DbSession, user: CurrentUser) -> PreferencesOut:
    """Allergies (hard blocks) and foods to avoid (soft), normalised (SUB-02)."""
    return preferences.to_out(await preferences.get_row(session, user))


@router.put("/me/preferences", response_model=PreferencesOut)
async def put_preferences(
    body: PreferencesIn, session: DbSession, user: CurrentUser
) -> PreferencesOut:
    return await preferences.put(session, user, body, await load_dictionary(session))
