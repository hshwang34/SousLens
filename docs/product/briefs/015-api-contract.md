# Brief 015 — API contract (backend ⇄ iOS)

All under `/v1`, bearer auth, snake_case, ISO-8601 UTC, the standard error envelope. Additive:
no existing field changes meaning, and clients that don't send the new fields keep working.

## Me

`GET /me` → **200** — `UserOut` gains two fields:

```jsonc
{
  "id": "uuid",
  "display_name": "string",
  "preference_units": "us|metric",
  "created_at": "…",
  "onboarded_at": "… | null",   // null → the app shows onboarding
  "role": "cook|creator|null"   // null until chosen
}
```

`PATCH /me` with `{"role": "cook|creator"}` → **200** `UserOut`. Unknown fields → 422.

`POST /me/onboarding/complete` (no body) → **200** `UserOut`. Idempotent: a second call keeps the
first `onboarded_at`.

## Preferences

`GET /me/preferences` → **200**, `PUT /me/preferences` → **200**. Three new fields:

```jsonc
{
  "allergies": ["peanut"],
  "avoid": ["cilantro"],
  "diets": ["vegetarian"],            // subset of: vegetarian, vegan, pescatarian, halal, kosher
  "cuisines": ["korean", "italian"],  // subset of: korean, italian, mexican, indian, japanese,
                                      //   chinese, thai, american, mediterranean, french
  "skill_level": "beginner|comfortable|confident|null",
  "updated_at": "…",
  "unrecognized": []
}
```

- On `PUT`, `allergies` and `avoid` keep today's replace semantics. **An omitted new field keeps
  its stored value** (older clients never wipe it). Sending `[]` / `null` clears it.
- Values outside the lists → 422 `VALIDATION_ERROR`. Lists are de-duplicated, order kept.

## Creators and follows

```jsonc
// CreatorSummary
{
  "id": "uuid",
  "display_name": "string",
  "bio": "string|null",
  "avatar_url": "string|null",
  "recipe_count": 4,
  "follower_count": 12,
  "is_following": false,
  "cuisines": ["korean"],          // from their recipes' tags
  "sample_recipe_titles": ["Kimchi Fried Rice", "…"]   // up to 2
}
```

| Endpoint | Result |
|---|---|
| `GET /creators/suggested?cuisines=korean,italian&limit=8` | **200** `{"items": [CreatorSummary]}`. Users with ≥1 published recipe, excluding the caller. Ranked by how many of their recipes are in the chosen cuisines, then recipe count, then name. `limit` 1–20, default 8. |
| `GET /creators/{id}` | **200** `{"creator": CreatorSummary, "recipes": [RecipeCard]}` (newest first). 404 if the user has no published recipe. |
| `PUT /creators/{id}/follow` | **200** `CreatorSummary` with `is_following: true`. Idempotent. 404 for self or a non-creator. |
| `DELETE /creators/{id}/follow` | **200** `CreatorSummary` with `is_following: false`. Idempotent. |
| `GET /me/following` | **200** `{"items": [CreatorSummary]}`, most recently followed first. |

`RecipeCard.creator` (`CreatorRef`) is unchanged. Seeded personas have no `avatar_url`; the app draws a monogram.

## Feeds

Both return `RecipePage` (`{"items": [...], "next_cursor": "string|null"}`), `limit` 1–50,
default 20, opaque `cursor`.

`GET /feed/for-you` — items are `RecipeCard` plus:

```jsonc
"feed": {
  "reason": "You have 8 of 9",     // display as is; also "Korean", "From Mina", "New"
  "coverage": 0.89,                // 0–1, null when the pantry is empty. Share of required
                                   //   ingredients found in the pantry, amounts ignored
  "can_make": false,               // the strict pantry-fit verdict (amounts checked)
  "allergy_conflict": "peanut|null" // when set, show "Contains peanut"
}
```

Ranking (deterministic, per request):
`score = coverage + 0.3·cuisine_match + 0.2·followed_creator − 0.5·diet_mismatch`, allergy
conflicts sorted after every other recipe, ties newest first. With an empty pantry `coverage`
counts as 0 and the reason falls back to cuisine / creator / "New".

`GET /feed/following` — `RecipeCard` items from followed creators, newest first. Following no one
→ `{"items": [], "next_cursor": null}`.
