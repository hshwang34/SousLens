# 014 — Record it while you cook: voice recipe capture

**Status:** approved · **Owner:** PM · **PR:** — · **Updated:** 2026-11-13

## Problem
The only way to put a recipe into Umma today is typing it in, field by field: title,
ingredients one sheet at a time, then steps. A mum who cooks by feel won't do that, and the
details that matter most (how hot, how long, how much) are exactly the ones she never writes
down. The video→recipe backend (brief 008) exists but has no app screens, and filming
yourself is its own chore.

## Who it's for
A creator, typically a parent, documenting a dish for their family while actually cooking it.
Their hands are busy and the phone is propped up on the counter.

## Storyboard
1. Mum taps **New recipe → Record while cooking**. Umma says one line: "I'm listening. Just
   cook and tell me what you're doing."
2. She cooks and talks: "First the pork belly goes in, no oil… now the kimchi, the old sour
   one…" Captions follow her words, and the screen stays awake.
3. She goes quiet while stirring. Umma waits for the pause, then asks one short question:
   "How long do you let it simmer?" She answers "about fifteen minutes", or says "skip".
4. Umma never talks over her, asks at most a handful of questions, and never asks the same
   thing twice.
5. She taps **Done**. Umma asks up to three last things she skipped ("How many people does
   this feed?").
6. Umma writes the recipe: title, ingredients, steps, cues, warnings, and her own phrases as
   creator notes. It opens in the editor with AI-drafted fields marked. She fixes what's
   wrong and publishes it for her son.

## What success looks like
- A creator records a real 30–45 minute cook without touching the phone between Start and
  Done.
- The agent asks only when something needed is missing. A tester never hears it interrupt
  mid-sentence.
- The draft has no invented numbers. Anything she didn't say is visibly "needs review".

## Acceptance criteria

**Entry and modes**
- [ ] Profile → **New recipe** opens a chooser with three options:
  - **Record while cooking** (voice).
  - **Record with camera**, shown with a "Coming soon" badge and disabled, with one line saying
    it's planned.
  - **Type it in**, which opens today's editor.

**Recording**
- [ ] Recording is visible and user-started. The screen shows:
  - the 012 voice bar (listening / thinking / speaking) and the input source, labelled
    honestly;
  - live captions;
  - elapsed time;
  - Pause and Done.
- [ ] Nothing is captured outside a session.
- [ ] Every utterance, question and answer is stored with its time since the session started.
- [ ] The screen stays awake while recording.
- [ ] If the app is killed or crashes, relaunching offers to resume or finish the session.
  Nothing she said is lost.

**The interviewer**
- [ ] The agent asks only after about 1.5 s of silence, never while she's speaking, and never
  while Umma itself is speaking or the session is paused.
- [ ] One question at a time. Each question is shown as a card while it's spoken, and it
  expires after about 20 s with no answer.
- [ ] Limits:
  - at least 45 s between live questions;
  - at most 6 live questions per session;
  - no repeat of a topic already answered or skipped.
- [ ] Topics it may ask about:
  - heat or oven temperature;
  - time;
  - quantity;
  - how to tell it's done;
  - servings;
  - prep or cut;
  - equipment.
- [ ] Commands it understands:
  - "Skip" drops the current question.
  - "Later" defers it to the wrap-up.
  - "Stop asking" turns live questions off for the rest of the session.

**Wrap-up and draft**
- [ ] After Done, up to 3 spoken questions on what's still missing, each skippable. Then a
  generating state that shows honest progress.
- [ ] The draft opens in the existing editor:
  - AI-drafted fields are labelled.
  - Quantities and times she never stated stay empty and are marked "needs review", never
    guessed.
  - Her own phrasing is kept as creator notes where it fits.
- [ ] Publishing uses the existing confirm flow. Nothing is published automatically.

**Cost, tiers and privacy**
- [ ] Voice runs on brief 012's stack: Free on-device, Paid through the server and the Gemini
  guard. Capture AI calls are priced into the usage ledger and count toward the per-user caps.
- [ ] Over the cap, recording still works. The draft is generated once AI is back, or she can
  type it in.
- [ ] Audio is never stored. Transcript events are deleted when the draft is published or
  discarded. The privacy page says so.
- [ ] Works on the mock AI provider end to end (AI-off still works).

## Out of scope
- Camera + voice capture, photos and step clips. It's a visible "Coming soon" option for now.
- Inferring step durations from the timestamps (v2). v1 records them.
- Gemini Live, a wake word, and proactive interjections.
- Recording from the Meta glasses.

## Open product questions
None. Answered in DECISIONS #25.

## Sequencing
1. This docs PR.
2. **Backend capture domain** (sessions, timestamped events, ask policy, interviewer and
   draft generator on the mock). It doesn't need voice audio, so it can start now.
3. **Brief 012's voice core** (session, voice bar, entitlement, Free and Paid transport). It is
   shared with cooking voice.
4. **iOS capture screens** on top of the voice core.
5. **Real Gemini** for the interviewer and generator, after the Gemini key arrives and a PM go.

## Engineering decisions (filled in by the lead while building)
- Port Retrace's Expert Interviewer modules (ADR-0001): the ask policy, the gap planner, the
  facts and notes builders, and the client gate/answer-window logic as a standalone
  coordinator. Its Gemini Live base class is not ported.
- Generation reuses the brief 008 extraction job, worker, `build_content` and `evidence_origin`
  labelling, with a new `capture` job kind.

## Risks / what could go wrong for users
- **Kitchen noise reads as speech, so the agent never finds a pause.** Mitigation: on-device
  voice-activity gating, and the wrap-up catches whatever live questions missed.
- **The agent feels naggy.** Mitigation: hard limits on the number and spacing of questions,
  "stop asking", and no repeated topics.
- **Long sessions drain the battery or get killed.** Mitigation: a local journal, resume on
  relaunch, and the screen stays awake on power.
- **Wrong transcription of numbers** ("fifteen" vs "fifty"). Mitigation: numbers come out of
  the wrap-up and editor review labelled, never silently trusted.
