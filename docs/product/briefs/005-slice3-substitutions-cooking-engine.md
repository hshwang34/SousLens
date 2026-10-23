# 005 — Slice 3: substitutions and cooking engine

**Status:** building · **Owner:** PM · **PR:** — · **Updated:** 2026-10-23

## Problem
Nobody can cook with the app yet. PRD §16 Slice 3, SUB-01..05, COOK-01..04 (typed), COOK-06..08,
J3 (4–6), J4 (typed path), §8.4–8.7, §11.1.

## Who it's for
Learner cooking a saved recipe on the phone, with the AI mocked.

## What success looks like
- Missing mirin → a qualified substitution with ratio, flavour/texture impact, confidence, risks →
  learner accepts → session shows the adapted step with "AI suggested adaptation" label → learner
  can revert.
- Start cooking → one step at a time, Next/Back, read aloud, repeat, timer suggestion the user
  confirms, typed "what does this mean?" answered with a source-step badge; kill the app →
  relaunch → same step, overlay and timers.

## Acceptance criteria
- [ ] `POST /v1/substitutions/suggest`: seed rules first, then `SubstitutionAdvisor`; output per
      PRD §8.4; allergy/safety precedence from `domains/safety`; `cannot_substitute` path
      (SUB-01/02/05).
- [ ] Session overlay: approve/revert per swap; original version never mutated; adapted step text
      labelled (SUB-03/04).
- [ ] `POST /v1/sessions` pins version, substitutions, step 0, pantry snapshot (COOK-01).
- [ ] `POST /v1/sessions/{id}/commands` per §11.1: `Idempotency-Key`, `expected_revision`,
      `user_confirmed`; 200 / duplicate 200 no-op / 409 STATE_CONFLICT / 422 CONFIRMATION_REQUIRED /
      404 for non-owner (COOK-02). Timer commands store absolute `target_at` (COOK-06).
- [ ] `POST /v1/sessions/{id}/ask` (typed) builds the §8.5 grounding packet, returns Appendix A
      contract with `grounding` refs and `grounded_session_revision`; mock coach answers from
      step text/cues (COOK-03/04). Stale revision → client shows "Based on previous step".
- [ ] `GET /v1/sessions/{id}` restores everything; complete/abandon + notes (COOK-07/08).
- [ ] iOS: Cooking screen (large type, step N of M, clip placeholder, Ask/Look(disabled)/Back/
      Next/Pause, timers, read-aloud via `SystemAudioOutput`), Assistant drawer, Session end,
      resume-on-launch banner, floating current-session entry.
- [ ] Gate tests: full recipe with accepted substitution; relaunch recovery; repeat Next with the
      same key advances once; creator publishes v2 mid-session → session stays v1.

## Out of scope
Voice input, real coach/vision models (Slice 4), glasses (6), public variants (P1).

## Open product questions
1. **Timer suggestion copy** — Options: A ("Start a 10-min simmer timer?" with Start/Skip),
   B (auto-create paused timer). **Recommendation:** A per PRD §6.1. → *Answer:* A (DECISIONS #14).

## Engineering decisions
- (filled in while building)
