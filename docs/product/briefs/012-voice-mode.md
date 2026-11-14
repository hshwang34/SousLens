# 012 — Voice mode: hands-free from pantry to plate

**Status:** draft · **Owner:** PM · **PR:** — · **Updated:** 2026-11-12

## Problem
Cooking happens with wet, busy hands. Today every step of Umma needs a tap: adding pantry
items, picking a recipe, moving through steps. Retrace showed that a voice-first coach feels
like a person in the kitchen. Umma needs that end to end, and the screen should follow
along instead of being the thing you operate.

## Who it's for
Home cooks with the phone propped up (often sideways) or wearing glasses, from "what do I have"
to the last step.

## What success looks like
- A tester starts voice mode and doesn't need to touch the phone until the meal is done:
  - pantry: "I've got eggs, rice, spinach…";
  - choosing: "what can I make?", "something quicker", "the second one";
  - cooking: "next", "I'm out of lemons", "set the timer".
- The screen visibly animates every state change and stays in sync with the voice.
- Talking over the coach works (Paid), and pots clattering don't cut it off.

## Acceptance criteria
**Session and screen**
- [ ] **Starting voice mode is visible:**
  - It starts from a "Start voice mode" button, followed by a spoken greeting.
  - A persistent voice bar shows listening, thinking or speaking, with live captions of both sides.
  - The mic ends on "stop", on the button, or after 10 minutes of silence. There is never passive
    listening outside a session.
- [ ] **Cards, not free-form UI:**
  - The server agent returns which card to show and its data: pantry list, recipe options, recipe
    detail, step, swap, timer, answer, safety notice, or "did you mean".
  - Every card is designed for light/dark and large text and is snapshot-tested.
  - Safety notices use the fixed solid style and the DECISIONS #15 wording, spoken verbatim.
- [ ] **Animated state:**
  - Next/back slides the step card and fills the segmented progress.
  - Repeat pulses the card.
  - A swap shows before → after and morphs into the step text.
  - Recipe options fan out; "the second one" zooms into the recipe.
  - Pantry items drop in dashed and turn solid on yes.
  - Reduce Motion turns all of these into crossfades.
- [ ] **One command path:** a tap and a voice command call the same server action, with an
      idempotency key and expected_revision, so saying and tapping "next" together advances once.
      The UI moves optimistically and visibly rolls back if the server refuses.
- [ ] **Landscape** on the voice session, cooking and recipe-picking screens. Cooking puts the
      step on the left two-thirds and the timers, this step's ingredients and the voice bar on the
      right. Other screens stay portrait.

**Conversation**
- [ ] **Pantry by voice:**
  - Items are extracted from speech and shown as unconfirmed.
  - The coach reads back the count plus anything ambiguous.
  - "Yes", "drop the spinach" or "cheddar" edit the list before saving. No silent writes.
- [ ] **Discovery:** "what can I make" ranks by pantry fit. Open requests (cuisine, time, "lighter")
      become visible, tappable filter chips over published recipes. "Something else", "the first
      one" and "quicker" work.
- [ ] **Cooking:** next, back, repeat, slower, pause, timers (offered, start only on yes), swaps
      ("I'm out of lemons", applied only on yes, "undo that" reverts), recipe Q&A and Look on
      request. The Step Oracle stays the only owner of step state.
- [ ] **Personality:** warm and friendly, with short lines on the cooking screens. Safety, allergy
      and doneness wording is never paraphrased.

**Tiers**
- [ ] **Free (on-device):** Apple speech recognition and voice. The core commands work offline.
      Fuzzy requests use deterministic matching. Barge-in is limited to short commands.
- [ ] **Paid (server, default):**
  - Echo-cancelled audio (iOS voice processing) is gated by on-device voice activity and streamed
    in batched chunks to our backend.
  - Server-side transcription, turn detection and barge-in.
  - The agent turn runs through the Gemini guard.
  - A server TTS voice streams back, and playback flushes immediately on barge-in.
  - Settings → Voice: "Run voice on this iPhone" is available to Paid users.
- [ ] **Tier plumbing:**
  - A server-side entitlement (`free` / `paid`) gates every server AI capability (voice, coach
    AI, Look, pantry photo, video extraction).
  - During the beta every account is `paid`, by config.
  - Over the budget cap, Paid falls back to the Free path with the "AI is resting" notice.
  - No StoreKit purchase yet. Price $4.99/mo or $39.99/yr is recorded for launch, not shown.
- [ ] **Cost:**
  - Audio is sent only during speech.
  - Server transcription and TTS usage is priced into the `ai_usage` ledger, under the
    $0.25/day per-person and $22/month hard caps.
  - A recorded-audio replay suite runs in CI with no spend.

**Honesty and privacy**
- [ ] **Mic label:** "glasses mic" only when HFP is verified. The voice bar names the input.
- [ ] **Paid audio is never stored:** audio is processed in memory, with no transcripts beyond the
      session turns already kept.
- [ ] **Updated wording:** the privacy policy, site copy and App Privacy answers describe both tiers.

## Out of scope
- StoreKit purchases and real charges (they need a PM go at launch).
- Wake word.
- Gemini Live, and video streaming to the model.
- Voice on the creator editor. Recording a recipe by voice is a separate capture screen, brief 014, which reuses this brief's voice core.

## Open product questions
None. Answered in DECISIONS #22.

## Engineering decisions (filled in by the lead while building)
- …

## Risks / what could go wrong for users
- **Barge-in false triggers from kitchen noise.** Mitigation: on-device echo cancellation plus
  voice-activity gating, server turn detection tuned on recorded kitchen audio, and a "mute"
  voice-bar control.
- **Latency on Paid** (network plus model). Mitigation: commands like next/back/repeat are
  recognised immediately from the partial transcript and acted on before the full turn finishes.
- **Cost if many testers cook daily.** Mitigation: the existing caps; audio is billed only while
  someone speaks.
