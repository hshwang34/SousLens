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
| POST | `/recipes/{recipe_id}/edit` | `{}` → **201 Draft** pre-filled from the latest published version, `recipe_id` set (REC-06). 409 `STATE_CONFLICT` if an open draft for that recipe already exists (body `details.draft_id`); at most one open draft per recipe, also under concurrent calls |
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
`ingredient_refs` entry must match an ingredient id (duplicate ingredient/step ids are also
problems). Publishing snapshots the draft into an immutable `recipe_versions` row
(`version_number` = previous + 1), updates `recipes.latest_version_id`, sets visibility public,
marks the draft `published`. A published draft is read-only (PATCH → 409). 422 `details.problems`
is the same `[{"field","message"}]` list as `validation.problems`.

Draft field notes (as implemented):

- `servings`, `prep_minutes`, `cook_minutes` are `int|null` on a Draft — `null` until the creator
  sets them; `servings ≥ 1` is a *publish* rule, not a PATCH rule (PATCH accepts `0` so the editor
  can show the inline problem). Ingredient `name` / step `instruction` may be `""` while drafting.
- Step `order` is rewritten from the array position on every save (`0..n-1`); send steps in the
  order you want them. A step's `order` in the body is ignored.
- `cover_image_url`: absolute `https://` URL only (scheme + host, valid port if any, no
  credentials, ≤ 2048 chars, no whitespace/control characters/backslashes anywhere in the raw
  value; not trimmed, stored exactly as sent); anything else → 422 `VALIDATION_ERROR` with
  `fields: ["body.cover_image_url"]`. Uploads with media ids arrive in Slice 5.
- PATCH tolerates the read-only keys (`id`, `recipe_id`, `status`, `validation`, `created_at`,
  `updated_at`) so a client may echo a whole Draft; any other unknown key → 422.
- **`null` in PATCH:** `null` for a *scalar* (`title`, `summary`, `cover_image_url`, `servings`,
  `prep_minutes`, `cook_minutes`, and nullable item fields like `unit`) clears it. `null` for an
  *array* (`tags`, `ingredients`, `steps`, `creator_notes`, `dietary_warnings`, and item arrays
  like `ingredient_refs`) → 422 `VALIDATION_ERROR` naming the field; send `[]` to empty it.
- **Text limits and hygiene (422 names the field, e.g. `body.steps.0.instruction`):**
  `title` ≤ 120 after trimming (stored trimmed); `summary` ≤ 1000; each tag 1–40 after trimming,
  stored lowercased (≤ 20 tags); each `creator_notes` / `dietary_warnings` / `success_cues` /
  `warnings` item ≤ 500; ingredient/step `id`, `ingredient_refs` items and `source_clip_id` ≤ 64;
  ingredient `name` ≤ 200, `unit` ≤ 32, `preparation` ≤ 200, `notes` ≤ 500; step `instruction`
  ≤ 2000, `creator_note` ≤ 500. Every text field rejects control characters (U+0000–U+0008,
  U+000B, U+000C, U+000E–U+001F, U+007F) and bidi controls (U+202A–U+202E, U+2066–U+2069).
  Line breaks (`\n`, `\r`) are allowed only in `instruction`, `summary`, ingredient `notes`,
  step `creator_note`, and the notes/warnings/cues list items. `GET /recipes` `query`/`tag`
  apply the same single-line check (422, never 500).
- `GET /recipes/drafts` lists every draft of mine including `status: "published"` ones
  (newest `updated_at` first); filter client-side for the "Drafts" section.
- Error `details` for 409 on `PATCH`/`publish` of a published draft: `{"recipe_id"}`.

## Public recipes (additive)

- `GET /recipes?query=` now matches **title OR any ingredient name**, case-insensitive (REC-02).
- `RecipeCard` and `RecipeDetail` gain `"saved": true|false|null` (null when unauthenticated) and
  `RecipeDetail` gains `"share_url"`.
- `GET /recipe-versions/{version_id}` (auth) → RecipeDetail for that exact version (REC-05: prior
  references keep working after an unpublish). The body is immutable: title, summary, tags and
  cover are snapshotted on the version too, so it is byte-identical after later versions and
  after an unpublish (only the caller-dependent `saved` can differ between callers). Returned only when at least one holds: the recipe is
  currently public, **or** the caller owns it, **or** the caller has a Save on it. Otherwise 404,
  indistinguishable from an unknown id (so a leaked version id alone reveals nothing). Slice 3 adds
  "caller owns a cooking session pinning this version" to the allow-list.
- Unpublished recipes: hidden from the list; `GET /recipes/{id}` → 404 for non-owners, 200 for the owner.

## Saves (REC-02)

| Method | Path | Response |
|---|---|---|
| POST | `/recipes/{id}/save` | 200 `{"recipe_id","saved":true}` (idempotent) |
| DELETE | `/recipes/{id}/save` | 200 `{"recipe_id","saved":false}` (idempotent, 200 even if not saved) |
| GET | `/me/saved` | `{"items":[RecipeCard]}` newest-saved first (recipes no longer visible to me are omitted) |
| GET | `/me/recipes` | `{"items":[MyRecipe]}` — MyRecipe = RecipeCard + `"visibility"`, `"has_open_draft": bool` |

## Share / deep links

- `share_url` = `https://souslens.app/r/{recipe_id}`; the app also accepts `souslens://recipe/{recipe_id}`.
  Universal-link association is a stub in this slice (the domain is not live); the custom scheme works.

## Seed

`fixtures/seeded_recipes/` grows to the five PRD Appendix B recipes (gochujang chicken, kimchi fried
rice, egg-and-tomato stir fry, garlic pasta, cucumber salad), each ≥ 5 steps, a creator note, a
warning where relevant, success cues; `fixtures/expected_outputs/recipes_list.json` regenerated.
