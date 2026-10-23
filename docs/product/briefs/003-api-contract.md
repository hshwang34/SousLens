# Brief 003 — Slice 1 API contract (backend ⇄ iOS)

All under `/v1`, bearer auth unless marked public, snake_case JSON, ISO-8601 UTC dates, the PRD
error envelope on every failure. Additive to the Slice 0 contract; nothing there changes shape.

## Drafts (creator authoring) — owner only, 404 for anyone else

| Method | Path | Body → Response |
|---|---|---|
| POST | `/recipes/drafts` | `{}` or any Draft fields → **201 Draft** |
| GET | `/recipes/drafts` | → `{"items":[DraftSummary]}` (mine, newest first) |
| GET | `/recipes/drafts/{id}` | → Draft |
| PATCH | `/recipes/drafts/{id}` | partial Draft fields (any subset; arrays replace whole) → Draft |
| DELETE | `/recipes/drafts/{id}` | → 204 |
| POST | `/recipes/drafts/{id}/publish` | `{}` → **201 PublishResult**; 422 `VALIDATION_ERROR` with `details` when not publishable |
| POST | `/recipes/{recipe_id}/edit` | `{}` → **201 Draft** pre-filled from the latest published version, `recipe_id` set (REC-06). 409 `STATE_CONFLICT` if an open draft for that recipe already exists (body `details.draft_id`) |
| POST | `/recipes/{recipe_id}/unpublish` | `{}` → 200 `{"recipe_id", "visibility":"private"}` (owner only) |

```jsonc
// Draft
{
  "id": "uuid", "recipe_id": "uuid|null", "status": "draft|published",
  "title": "string|null", "summary": "string|null", "tags": ["string"],
  "cover_image_url": "string|null", "servings": 4, "prep_minutes": 15, "cook_minutes": 20,
  "ingredients": [ /* same shape as RecipeDetail.ingredients; "id" is a client-chosen string like "ing-1" */ ],
  "steps":       [ /* same shape as RecipeDetail.steps; "id" like "step-1"; "order" 0-based; evidence_origin defaults to "creator_authored" */ ],
  "creator_notes": ["string"], "dietary_warnings": ["string"],
  "validation": { "publishable": false, "problems": [ {"field": "ingredients", "message": "Add at least one ingredient"} ] },
  "created_at": "iso", "updated_at": "iso"
}
// DraftSummary = Draft minus ingredients/steps/creator_notes/dietary_warnings, plus "ingredient_count","step_count"
// PublishResult
{ "recipe_id": "uuid", "recipe_version_id": "uuid", "version_number": 1, "share_url": "https://souslens.app/r/{recipe_id}" }
```

Publish rules (REC-04): title (1–120 chars), servings ≥ 1, ≥ 1 ingredient with a non-empty name,
≥ 1 step with non-empty instruction; step `order` must be 0..n-1 after normalisation; every
`ingredient_refs` entry must match an ingredient id. Publishing snapshots the draft into an
immutable `recipe_versions` row (`version_number` = previous + 1), updates `recipes.latest_version_id`,
sets visibility public, marks the draft `published`. A published draft is read-only (PATCH → 409).

## Public recipes (additive)

- `GET /recipes?query=` now matches **title OR any ingredient name**, case-insensitive (REC-02).
- `RecipeCard` and `RecipeDetail` gain `"saved": true|false|null` (null when unauthenticated) and
  `RecipeDetail` gains `"share_url"`.
- `GET /recipe-versions/{version_id}` (auth) → RecipeDetail for that exact version, regardless of
  the recipe's current visibility (REC-05: prior references keep working; ids are unguessable UUIDs).
- Unpublished recipes: hidden from the list; `GET /recipes/{id}` → 404 for non-owners, 200 for the owner.

## Saves (REC-02)

| Method | Path | Response |
|---|---|---|
| POST | `/recipes/{id}/save` | 200 `{"recipe_id","saved":true}` (idempotent) |
| DELETE | `/recipes/{id}/save` | 200 `{"recipe_id","saved":false}` (idempotent, 200 even if not saved) |
| GET | `/me/saved` | `{"items":[RecipeCard]}` newest-saved first |
| GET | `/me/recipes` | `{"items":[MyRecipe]}` — MyRecipe = RecipeCard + `"visibility"`, `"has_open_draft": bool` |

## Share / deep links

- `share_url` = `https://souslens.app/r/{recipe_id}`; the app also accepts `souslens://recipe/{recipe_id}`.
  Universal-link association is a stub in this slice (the domain is not live); the custom scheme works.

## Seed

`fixtures/seeded_recipes/` grows to the five PRD Appendix B recipes (gochujang chicken, kimchi fried
rice, egg-and-tomato stir fry, garlic pasta, cucumber salad), each ≥ 5 steps, a creator note, a
warning where relevant, success cues; `fixtures/expected_outputs/recipes_list.json` regenerated.
