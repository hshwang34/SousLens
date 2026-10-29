# 007 — Slice 4: real voice and vision (Gemini, capped)

**Status:** approved · **Owner:** PM · **PR:** — · **Updated:** 2026-10-28

## Problem
Every AI answer today comes from the mock. Testers can't ask a real question, scan a real pantry,
or get a real look at their pan, so the pilot can't show the product's core promise.

## Who it's for
Home cooks mid-recipe (hands busy, asking out loud), and anyone scanning their pantry.

## What success looks like
- A cook asks "how thin should I slice the onion?" by voice and hears a sourced answer, cited to
  the step, within about 3 s of the transcript being confirmed.
- A cook photographs the pan and gets appropriately uncertain coaching that never certifies
  doneness or safety.
- Spend can't exceed the $25/month cap, whatever testers do.

## Acceptance criteria
- [ ] `GeminiProvider` implements the coach, pantry, substitution and visual-observer Protocols
      with the `google-genai` SDK. Every response is parsed into the existing Pydantic contracts:
      one retry on malformed output, then an editable partial result or error. Nothing is fabricated.
- [ ] Per-capability model settings (DECISIONS #19), timeouts (20 s interactive) and bounded retries.
- [ ] Cost guard: an `ai_usage` ledger priced from `usage_metadata` with a dated price table. A
      pre-flight reservation; per-user $0.25/day; a soft-degrade at $15 and hard stop at $22 per
      UTC month. Over the cap, the user sees "AI is resting — demo answers for now" and the labelled
      mock path; nothing fails silently.
- [ ] Safety post-filters and the DECISIONS #15 templates apply to real model output exactly as to
      the mock. Recipe text and photos are passed as data, never as instructions (prompt-injection
      tests included).
- [ ] iOS voice: hold-to-talk using on-device SFSpeechRecognizer. The transcript is shown and
      editable before sending, and answers are spoken with AVSpeechSynthesizer (Repeat and Slower
      work). The mic route label stays honest (iPhone mic unless HFP is verified).
- [ ] iOS Look: one user-initiated photo for the current step. The image is processed in memory
      and never stored. The answer is labelled as AI observation with a confidence bin.
- [ ] A replayable fixture suite (recorded Gemini responses) runs in CI with no network and no spend.
      One opt-in live smoke (`make ai-live-smoke`) costs less than $0.05.
- [ ] `AI_PROVIDER=mock` behaviour is unchanged; the full existing suite passes.

## Out of scope
Gemini Live streaming, Gemini audio STT/TTS, video (brief 008), glasses (brief 009).

## Open product questions
None. The voice route, models and caps are settled in DECISIONS #18–#19.

## Engineering decisions (filled in by the lead while building)
- …

## Risks / what could go wrong for users
- Kitchen noise hurts on-device recognition. Mitigation: the editable transcript plus "Type instead".
- A model claims something is done or safe. Mitigation: the existing deterministic templates and
  post-filter; tests run against recorded adversarial outputs.
