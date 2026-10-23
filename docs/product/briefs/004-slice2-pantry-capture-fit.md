# 004 — Slice 2: pantry capture and fit

**Status:** building · **Owner:** PM · **PR:** — · **Updated:** 2026-10-23

## Problem
The learner cannot tell whether they can make a recipe with what they have. PRD §16 Slice 2,
PAN-01..05, FIT-01..03, J2, J3 (steps 1–3), §8.3, §12.1–12.2.

## Who it's for
Learner at home, hands dirty, phone propped up.

## What success looks like
- Say "I have chicken thighs, two onions, gochujang and honey" → a review list of candidates →
  accept some → pantry updated with timestamps and source.
- Take one photo → candidates with confidence bins and an "unlabeled jar → unknown" entry.
- Open a recipe → Check my pantry → Available / Missing / Uncertain with a reason per ingredient.

## Acceptance criteria
- [ ] Backend pantry CRUD with ownership (PAN-01, PAN-05).
- [ ] `POST /v1/pantry/observations` (mode transcript|photo) → ephemeral candidates with
      `raw_label, canonical_name, quantity, unit, confidence, evidence, action`; nothing persisted
      (PAN-02/03). Mock provider: deterministic transcript parser + fixture lookup for photos.
- [ ] `POST /v1/pantry` with selected candidates only; duplicate → merge prompt, never silent
      (PAN-04). Transient images deleted after processing (PRIV-01).
- [ ] `app/domains/matching`: normalization (casefold, singular/plural, alias dictionary seeded in
      `ingredients`), qualifiers preserved, available/uncertain/missing/optional_missing, coverage
      score with per-ingredient explanation, unit conversion tables without mass↔volume guessing
      (FIT-01..03, §12.1–12.2). `POST /v1/recipe-versions/{version_id}/fit` (see 004-api-contract.md).
- [ ] iOS: Pantry tab (list, add/edit/delete, provenance badges), mic push-to-talk → transcript →
      Scan review, photo capture → Scan review, item-level accept/reject; Pantry fit screen with
      rationale.
- [ ] Fixture tests: 15 transcripts, blurry image → uncertain, scallion=green onion,
      gochujang≠gochugaru, 1 egg vs 3 eggs → uncertain.

## Out of scope
Substitutions (Slice 3), real vision model (Slice 4), glasses camera (Slice 6), quantities
reconciliation (P1).

## Open product questions
None blocking; PRD §8.3 bins (>0.85 / 0.6–0.85 / <0.6) are the defaults.

## Engineering decisions
- Contract committed to main before branching (`004-api-contract.md`); fit lives at
  `POST /v1/recipe-versions/{id}/fit` with the same access rule as reading that version.
- **Backend**: migration 0003 drops the Slice 0 `source_image_key` column (no image column anywhere),
  renames source `transcript`→`voice` and status `applied`→`confirmed`, adds CHECKs, and keeps
  `source_observation_id` without a foreign key so provenance survives the 24 h purge.
- Photos are read with a hard size cap and processed in memory; a test fails on any write-mode file
  open or tempfile use during an upload above Starlette's spool threshold.
- Ingredient dictionary (`fixtures/ingredients.json`, 132 entries) is seeded idempotently; a seed with
  two entries claiming one alias fails. Entries list the qualifiers they imply, so "dried cilantro"
  ≠ cilantro and "cooked rice" ≠ rice; allergen-bearing words are never stripped (peanut oil ≠
  vegetable oil). Generic names ("chicken", "pepper") match as uncertain in both directions.
- Fit: an insufficient amount in a known unit is uncertain (PRD §17.2 scenario 3); recipe-only units
  ("clove") are never converted; "X or Y" matches either; several pantry entries may add up.
- Transcript parser never invents numbers ("some", "a few", packaging words → unknown amount).
- Per-user advisory locks serialise pantry writes and observation creation; the rate limit counts
  only created observations. Revisit holding the lock during the provider call in Slice 4.
- Malformed provider output: retry once, then 502 `AI_OUTPUT_INVALID` (retryable).
- Same ingredient twice in one request with no existing match → 422 (not 409); `merge_into` must
  target the caller's own item with the same normalised name; `quantity_is_estimate` is forced false
  unless the item is a photo item with a quantity; any quantity PATCH clears it.
- Transcript eval: the 15 fixtures score precision/recall 1.0 against the deterministic mock parser.
  They were written alongside the parser, so this proves coverage of listed cases, not real
  speech-to-text accuracy (that is a Slice 4 measurement).
