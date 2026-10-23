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
- (filled in while building)
