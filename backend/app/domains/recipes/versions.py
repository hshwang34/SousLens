"""Reading a ``recipe_versions`` row as served (shared by the read side and the editor)."""

from __future__ import annotations

from typing import TypedDict

from app.db.models import Recipe, RecipeVersion


class VersionMeta(TypedDict):
    title: str
    summary: str | None
    tags: list[str]
    cover_image_url: str | None


def version_meta(recipe: Recipe, version: RecipeVersion) -> VersionMeta:
    """Display metadata snapshotted on the version at publish time.

    Every version written by publish/seed has a non-null ``title`` (a publish rule), so a null
    title marks a row that predates the snapshot columns; only then do we fall back to the
    mutable ``recipes`` columns, for all four fields together.
    """
    if version.title is None:
        return VersionMeta(
            title=recipe.title,
            summary=recipe.summary,
            tags=list(recipe.tags),
            cover_image_url=recipe.cover_image_url,
        )
    return VersionMeta(
        title=version.title,
        summary=version.summary,
        tags=list(version.tags or []),
        cover_image_url=version.cover_image_url,
    )
