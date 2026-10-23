# 003 — Slice 1: browse, author, publish, share

**Status:** in review · **Owner:** PM · **PR:** backend #3, iOS #4 · **Updated:** 2026-10-23

## Problem
Creators cannot yet put a recipe into the system; learners cannot save one. PRD §16 Slice 1,
requirements REC-01..06, J1 (text path only).

## Who it's for
Creator (friend / enthusiastic cook) writing a recipe by hand; learner browsing and saving.

## What success looks like
- A creator writes a recipe, previews it, publishes v1, gets a share link; edits it and publishes
  v2; anything that pinned v1 still sees v1.
- A learner searches by title or ingredient, saves a recipe, and finds it in Saved after relaunch.

## Acceptance criteria
- [ ] Backend: `POST/PATCH /v1/recipes/drafts`, `POST /v1/recipes/drafts/{id}/publish` with
      validation (title, ≥1 ingredient, ≥1 step, servings) → immutable `recipe_versions` row,
      `version_number` increments, `recipes.latest_version_id` updated; publishing an edited
      published recipe creates a new draft → new version (REC-04/06).
- [ ] `POST/DELETE /v1/recipes/{id}/save` idempotent (REC-02); `GET /v1/me/saved`.
- [ ] Search matches title and ingredient names (REC-02).
- [ ] Unpublish hides from feed; prior versions remain fetchable by id (REC-05).
- [ ] Share link `souslens://recipe/{id}` + `https://souslens.app/r/{id}` universal-link stub handled
      by the app (REC-01).
- [ ] iOS: Creator editor (metadata, ingredient editor with quantity/unit/optional/preparation,
      step editor with cues/warnings/notes, reorder), draft autosave, preview, Publish with
      confirmation; Profile lists my drafts and published recipes; Saved tab; share sheet.
- [ ] Seed grows to the five Appendix B recipes.
- [ ] Gate test: publish v1 → edit → publish v2 → v1 JSON unchanged (byte-equal).

## Out of scope
Video import/extraction (Slice 5), forks/follows (P1), ratings.

## Open product questions
1. **Who may publish in the pilot?** — Options: A (any signed-in tester), B (allowlisted creators).
   **Recommendation:** A, pilot is 5–10 known people. → *Answer:* A — any signed-in tester may publish (DECISIONS #7).

## Engineering decisions
- Built as two PRs (backend, iOS) stacked on the Slice 0 branches (DECISIONS #8); shared contract in
  `003-api-contract.md`.
- **Backend**: a version snapshot owns *everything it serves*: title, summary, tags, cover, servings,
  times, ingredients, steps, notes, warnings (fix round 1). `GET /recipe-versions/{v1}` is
  byte-identical after v2 and after unpublish. `recipes.title/summary/tags/cover_image_url` stay as
  listing/search metadata mirrored from the latest publish.
- `recipe_versions` is append-only via DB triggers (migration 0002): a row-level BEFORE UPDATE/DELETE
  trigger and a statement-level BEFORE TRUNCATE trigger (row triggers skip TRUNCATE, including
  `TRUNCATE … CASCADE` from `recipes`/`users`). Both honour one transaction-local escape hatch,
  `SET LOCAL souslens.unlock_versions = 'on'`; the app never sets it (the test reset does).
- **PRIV-02 (data controls) must unlock explicitly.** Any account/recipe deletion flow cascades from
  `users`/`recipes` into `recipe_versions` and will be refused by the triggers. That flow must run
  `SET LOCAL souslens.unlock_versions = 'on'` inside its own transaction, and should first decide
  the policy for versions pinned by other users' sessions (`cooking_sessions.recipe_version_id` is
  `ON DELETE RESTRICT`).
- One open draft per recipe: `start_edit` locks the recipe row and a partial unique index
  `uq_recipe_drafts_one_open_per_recipe (recipe_id) WHERE status IN ('editing','extracting','review')`
  backs it; concurrent `/edit` → one 201, the rest 409 with `details.draft_id`.
- Draft text hygiene: one shared validator rejects C0 controls (except tab/newline/CR), DEL and bidi
  override/isolate controls in every text field; newlines only in instruction, summary, notes,
  warnings and cues; per-field length limits (see the contract). Same check on `?query=`/`?tag=`.
- Search is `recipes.title ILIKE` OR `recipe_versions.search_text ILIKE` (lowercased title +
  ingredient names written at publish/seed; backfilled by 0002). No full-text engine.
- Publish is one transaction with the draft and recipe rows locked; `version_number = max+1`;
  `published_at` set on first publish only (republishing doesn't bump feed position). Slug = slugified
  title with `-2`, `-3` suffixes; never changes on republish. Concurrent first publishes take
  `pg_advisory_xact_lock(hashtext(base_slug))` and insert in a SAVEPOINT that retries the next
  suffix on a unique violation (5 tries, then 409), so they never 500.
- `/recipe-versions/{id}` is readable only by the public, the owner, or a user who saved the recipe
  (security review); Slice 3 adds "caller has a session pinning this version".
- `cover_image_url` must be an absolute https URL without credentials (≤ 2048); real uploads with
  media ids arrive in Slice 5.
- Draft arrays are size-limited (≤200 ingredients, ≤100 steps, ≤50 notes/cues/warnings, ≤20 tags) as
  a denial-of-service guard. Step `order` is derived from array position.
- A presented-but-invalid bearer on a public route is a 401, never silently anonymous.

## Risks
- Validation too strict blocks creators; too loose publishes junk. Keep required set minimal and
  show inline reasons.
