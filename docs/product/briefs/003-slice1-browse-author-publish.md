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
- (filled in while building)

## Risks
- Validation too strict blocks creators; too loose publishes junk. Keep required set minimal and
  show inline reasons.
