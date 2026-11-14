# 016 — Live pantry scan

**Status:** approved (direction, 2026-11-13) · spend gate open · **Owner:** PM · **PR:** — · **Updated:** 2026-11-13

## Problem
Adding a pantry today means speaking a list, taking one photo at a time, or typing, and then
ticking every item. A real kitchen holds 30–40 things across a fridge, cupboards and shelves, so
stocking the pantry is the slowest part of the first evening. The cook-tonight journey capture of
2026-11-13 shows the cost. A cook who listed seven items
still got "You're missing 4 and check 4" on Pantry fit.

## Who it's for
The learner on first run, or at the start of a cooking week, standing in the kitchen with the
iPhone in hand. Glasses come later on the same path.

## What success looks like
- A cook pans the camera across the fridge and a cupboard. Each new ingredient they point at
  appears as a word on screen within about 2 seconds and drops into a basket.
- Pointing at the same jar again never adds it twice.
- When they tap Done, items Umma was sure about are already in the pantry. They answer only the
  few it wasn't sure about, plus any that match something already in the pantry.
- A two-minute scan of a stocked kitchen leaves a pantry good enough that Pantry fit shows mostly
  Available.

## Acceptance criteria
- [ ] **Start and stop.** Pantry shows a Live scan entry. The camera runs only while the scan
      screen is open, with a visible "Scanning" indicator and a countdown. A scan stops at 2
      minutes. "Keep scanning" starts a new session and keeps the basket.
- [ ] **Detection.** Gemini Live reports items through an `add_item(name, kind, confidence)` tool
      call. The app never plays model audio. Frames are sent at no more than 1 per second and are
      never stored on the phone or the server.
- [ ] **No duplicates.** Every reported item is normalized on the backend with the existing
      ingredient matcher. A repeat of a basket item (including synonyms, e.g. "shoyu" after "soy
      sauce") shows a brief "already have" pulse and adds nothing. Distinct allergen variants
      stay distinct (tamari is not soy sauce).
- [ ] **Animation.** A new item appears as a word chip, then flies into the basket counter. With
      Reduce Motion on, it fades instead.
- [ ] **Remove.** The cook can tap ✕ on any basket item during the scan. It is never saved.
- [ ] **Finish.** On Done, high-confidence new items are saved to the pantry with source `live`
      and an "Auto-added" chip. Medium and low-confidence items, and items matching an existing
      pantry item, go to a short review (tick, merge or keep both). Nothing in that review is
      saved without a tap.
- [ ] **Undo.** Auto-added items can be removed from the pantry list like any other item.
- [ ] **Spend.** Each scan reserves its worst-case cost before the token is issued. Over a cap, or
      over the per-user scan limit, the scan doesn't start and the cook is offered the photo or
      voice path. `ai_usage` shows one row per session.
- [ ] **AI-off.** With `AI_PROVIDER=mock`, Live scan replays a demo item script labelled "Demo
      mode — not a real detection", and nothing from it is auto-saved.
- [ ] **Keys.** The phone only ever holds a single-use token valid for a few minutes, locked to
      the model, instructions and tool. No provider key on the phone.

## Out of scope
- Boxes or labels pinned to item positions. The PM confirmed positions aren't needed.
- Quantities from video. Counts stay empty or marked as estimates, per PRD §8.3.
- Glasses camera. It plugs into the same frame stream after Slice 6 ships.
- Spoken narration by the model ("Got the soy sauce").
- Expiry or freshness detection, and automatic pantry decrement.
- Onboarding (brief 015) linking to Live scan. That's a one-line follow-up once this ships.

## Open product questions
1. **Engine?** — Options: Gemini Live (streamed, cheapest, lowest latency), a frame loop via our
   backend (reuses today's photo scan), OpenAI Realtime. **Recommendation:** Gemini Live.
   → *Answer:* Gemini Live (PM, 2026-11-13). Logged as DECISIONS #28.
2. **What does the cook confirm?** — Options: one tap for the whole basket, nothing (auto-save
   with undo), only unsure items. **Recommendation:** one tap for the whole basket.
   → *Answer:* only unsure items (PM, 2026-11-13). Logged as DECISIONS #28.
3. **Spend go.** → *Answer:* PM supplied the keys and asked for a real test (2026-11-13). Spike run.
4. **Per-user cap for live scans?** A 2-minute scan costs about $0.15 (spike), so the $0.25/day cap allows
   1–2. Options: keep it, a separate live-scan allowance, or cut cost first (session rotation).
   **Recommendation:** cut cost first, then re-measure. → *Answer:* pending.

## PR sequence
0. Docs: this brief and DECISIONS #28.
1. Spike, not merged. A script mints a token and runs Live against recorded fridge and cupboard
   video. It measures recall, false detections, time to first item, duplicates and cost per minute,
   and checks the model stays silent and tool-only. Go/no-go before PR 2.
2. Backend: `POST /v1/ai/live-token` (ephemeral token locked to model, instructions and tool;
   `pantry_live` cost reservation; per-user hourly limit; mock path over caps).
3. Backend: live-scan basket (`/v1/pantry/live-scans`: create, add item with normalize and
   dedupe, remove, finish with auto-save of high-confidence items). Adds the `live` source.
4. iOS: camera frame stream (`AVCaptureVideoDataOutput`, 1 fps, ~768 px JPEG) behind
   `feature.capture.liveScan`.
5. iOS: Live API WebSocket transport plus a fake transport for tests and mock mode.
6. iOS: Live scan screen, basket animation, short review, "Auto-added" chip with undo.
7. Smoke: UmmaSmoke drives the flow with the fake transport. A device check on a real kitchen.

## Spike results (2026-11-13, real `gemini-3.8-live`, two runs)
Four generated kitchen scenes (fridge door, fridge shelf, cupboard, counter; 33 items), panned
at 1 frame/s for 28 frames, ending with a revisit of the fridge door. The labels were cleaner
than a real kitchen's, so these numbers are optimistic until a real device test.
- **Phone path works.** A single-use token locked to the model, instructions and tool (v1alpha
  `auth_tokens`) connected and ran the session with no API key on the "phone".
- **Video alone never triggers the model.** Video-only sessions close for "client inactivity". With
  silent audio they stay open, but the model never takes a turn. The client must send a short
  text nudge every few frames ("Report any new items now visible") plus silent 16 kHz audio to
  keep the session alive.
- **Detection:** 33/33 and 32/33 items reported, 0 invented. 31 and 30 at high confidence;
  "ginger" and "peanut butter" came back medium. The first item arrived at 3.8–4.5 s. Items
  arrive in bursts at each nudge (roughly every 5–6 s), so the nudge rate sets the latency.
- **Dedupe:** the revisit of the fridge door added nothing, and the model repeated itself only 1–2 times
  after an `already_in_basket` reply. Two matcher gaps: "long grain rice" doesn't map to rice,
  and "chopped tomatoes" (canned) collapses into fresh "tomatoes", so the counter's tomatoes were
  dropped as a duplicate. Both are fixed in PR 3 or the dictionary.
- **It speaks anyway.** It said "The items currently visible are already recorded" for 5–9 s of
  audio per run despite the instructions. Harmless, because the app never plays it.
- **Cost is higher than first estimated.** Each nudge is a turn that re-reads the whole growing
  context: 9 turns billed 43.4k prompt tokens for 36 s, about $0.04, or roughly $0.15 for a
  2-minute scan, not "under a cent". Mitigations for PR 2/5: rotate to a fresh session every
  ~30 s carrying the basket names, or use the context-window sliding window, and nudge only when
  frames change. At today's $0.25/day per-user cap that's 1–2 full scans a day unless the cap
  changes.
- **Spike spend:** about $0.35 in total (scene images plus four Live sessions).

## Engineering decisions (filled in by the lead while building)
- Dedupe lives on the backend (`domains/matching/normalize.py::normalize`) so there is one
  matcher. The tool response tells the model the item is already in the basket.
- The phone connects straight to Gemini with an ephemeral token (PRD §9.3's planned
  `/ai/live-token`). Because the server can't see live usage, the token's lifetime is the spend
  ceiling. The full ceiling is reserved and settled.
- No session compression or resumption. A 2-minute cap per session is simpler than handling
  GoAway and resumption.

## Risks / what could go wrong for users
- **A confident false detection lands in the pantry** and Pantry fit says "Available" for
  something they don't have. Mitigations: high confidence only, the "Auto-added" chip, undo, ✕
  during the scan, and the spike measuring the false-positive rate before we build.
- **Ephemeral tokens are a preview API (`v1beta`).** If Google changes it, scanning breaks. The
  photo and voice paths stay as the fallback.
- **The model speaks anyway.** Audio is discarded and not played. Spoken output still costs a
  little and is covered by the reservation.
- **Privacy expectation.** Streaming video feels different from one photo. The camera copy, the
  indicator and the countdown must make it obvious when Umma is looking.
