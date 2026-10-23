# 003 — Slice 1: browse, author, publish, share

**Status:** building · **Owner:** PM · **PR:** — · **Updated:** 2026-10-20

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
- **Backend**: title/summary/tags/cover stay mutable recipe metadata (PRD §10); a version snapshot
  owns servings, times, ingredients, steps, notes, warnings. So an old version shows the recipe's
  *current* title. Historical titles would need columns on `recipe_versions` (not done; raise if
  wanted).
- `recipe_versions` is append-only via a DB trigger (migration 0002) with a transaction-local operator
  escape hatch (`SET LOCAL souslens.unlock_versions='on'`) for future account-deletion flows; FK
  cascades from `recipes`/`users` hit the trigger, so PRIV-02 deletion must unlock explicitly.
- Search is `recipes.title ILIKE` OR `recipe_versions.search_text ILIKE` (lowercased title +
  ingredient names written at publish/seed; backfilled by 0002). No full-text engine.
- Publish is one transaction with the draft and recipe rows locked; `version_number = max+1`;
  `published_at` set on first publish only (republishing doesn't bump feed position). Slug = slugified
  title with `-2`, `-3` suffixes; never changes on republish.
- `/recipe-versions/{id}` is readable only by the public, the owner, or a user who saved the recipe
  (security review); Slice 3 adds "caller has a session pinning this version".
- `cover_image_url` must be an absolute https URL without credentials (≤ 2048); real uploads with
  media ids arrive in Slice 5.
- Draft arrays are size-limited (≤200 ingredients, ≤100 steps, ≤50 notes, ≤20 tags, text ≤2000) as a
  denial-of-service guard. Step `order` is derived from array position.
- A presented-but-invalid bearer on a public route is a 401, never silently anonymous.

## Risks
- Validation too strict blocks creators; too loose publishes junk. Keep required set minimal and
  show inline reasons.
