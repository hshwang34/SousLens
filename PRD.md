# SousLens — Product Requirements Document

**Version:** 1.0 | **Date:** October 15, 2026 | **Status:** Build-ready MVP specification
**Audience:** Product owner, Claude Code, iOS/backend engineers, designer, test users
**Primary platform:** iOS + supported Meta AI glasses | **Working product name:** SousLens
**Product category:** Social recipes × pantry intelligence × contextual cooking education

> **North star:** Record a recipe once. Teach anyone to cook it, using the ingredients they actually have.
>
> **Build principle:** A complete end-to-end demonstration beats a broad, half-finished consumer application.

## 0. How to use this document

This is the source of truth for an initial solo-developer/portfolio MVP. Claude Code should build in vertical slices, starting with iPhone-only operation, and add Meta glasses as an optional input/output interface only after the same cooking-session logic works on a phone. Requirements are marked **P0** (MVP must-have), **P1** (strong next increment), and **P2** (later). Do not silently expand P0 scope. If a specific provider SDK changes, preserve product behavior and update the adapter rather than replacing the product requirements.

**Assumptions chosen deliberately:**
- Product is meant to be **shown and tested** by ~5–10 friends/creators, not launched at social-network scale in v1.
- Solo developer already has experience with SwiftUI, Meta Wearables DAT, Python/FastAPI, Gemini Live, and FFmpeg through Retrace/SmartSight.
- First public recipe is an original, permissioned cooking demonstration; seed content is created or licensed, not copied from third-party social videos without permission.
- A supported pair of Meta glasses and iPhone are available for device tests, but the MVP must work without the glasses.
- All AI suggestions are advisory. Human users control the stove, cooking safety, ingredient choices, and step progression.
- An English-language, US-unit prototype is the baseline. Support metric display of quantities; localization follows.

**Explicit decisions:**
1. iOS companion app is the home for discovery, creation, pantry, and sessions.
2. Creator recipes have an **immutable published version**, ordered steps, source attribution, optional clips, and explicit tips/warnings.
3. **SousLens is a cooking teacher**, not an unbounded recipe-generation chatbot. All instruction begins from a saved/published recipe.
4. Pantry observations are user-confirmed records with uncertainty and timestamps, not automated truth about food quantity/freshness.
5. The cooking-session **Step Oracle** in the backend owns canonical step state; the LLM never edits state directly.
6. Camera inspection is opt-in/on-demand by default. Continuous ambient AI observation is not required for launch.
7. Structured SQL retrieval suffices for P0; do **not** build RAG/vector search unless tests demonstrate the need.
8. No production dependence on experimental wearable microphone capture or unrelated Web Apps surfaces.

---

## 1. Product overview

### 1.1 Problem

Cooking content is often optimized for discovery, not execution. A user sees a creator's recipe but must manually parse ingredients and quantities, check the kitchen, guess substitutions, repeatedly touch a phone with messy hands, rewind videos to find a technique, and decide whether what is happening looks right. Conventional recipe apps store the instructions; they rarely provide context-aware education about *this user's current ingredients, cooking conditions, and progress*.

Creators likewise struggle to transfer tacit knowledge: "chop until it looks like this," "the sauce should coat the spoon," or "add a little more water at this texture." Video contains that knowledge but is not easily queryable or linked to individual procedural steps.

### 1.2 Product vision

SousLens converts creators' cooking knowledge into **interactive, personalized lessons**. A creator can publish a recipe as a reusable structured procedure; a learner can check their pantry through voice/camera, adapt the recipe with transparent substitutions, and cook using an AI assistant on an iPhone or connected smart glasses. Learners can later save their own variants, with original creator credit retained.

### 1.3 Positioning

**For** home cooks who discover recipes from real people and want to actually make them, **SousLens** is a recipe-sharing and AI cooking-teaching platform that adapts instructions to their pantry and guides execution hands-free. **Unlike** a static recipe feed or generic chatbot, it stays grounded in a specific creator's demonstrated recipe, preserves step state, and can use visual context from a phone or smart glasses when asked.

### 1.4 Non-goals

Not a grocery delivery business, nutrition/medical system, general-purpose camera surveillance product, social-media scraping platform, fully autonomous cooking robot, or real-time food-safety certification service. No claims of detecting food doneness, allergens, pathogens, or safe internal temperatures from images alone.

### 1.5 Retrace inheritance

Original Retrace primitive: **first-person capture → structured expert procedure + source clips → grounded live coaching → optional camera-based verification**. SousLens adds domain-specific `Recipe`, `Ingredient`, `Pantry`, `Substitution`, and `CookingSession` primitives. Reuse concepts, extract/validate/plan stages, step-clip generation, Gemini Live turn-taking, and server-authoritative progression, but do not require a general-purpose workflow platform.

---

## 2. Users, jobs to be done, and problems

### 2.1 Primary: Learner / home cook

Profile: beginner or intermediate cook, already saves recipes from friends/creators, often cooks while multitasking, may own Meta AI glasses but usually has an iPhone.

Jobs:
- "When I see a recipe I want to make, tell me whether I can make it with my actual ingredients."
- "When I don't have an ingredient, help me make a sensible substitution without changing the dish unexpectedly."
- "While my hands are busy, tell me what to do next and answer context-specific questions."
- "Show me what the creator meant when they said 'finely chopped' or 'until glossy.'"
- "Let me save what I changed and recreate my version next time."

### 2.2 Secondary: Recipe creator / knowledgeable cook

Profile: friend, family member, enthusiastic home cook, food creator, or instructor.

Jobs:
- "Turn my written recipe and optional demo video into something others can successfully reproduce."
- "Publish ingredients, steps, advice, warnings, and clips without spending hours authoring."
- "Let people cook my recipe while preserving attribution and linking back to the original."

### 2.3 Tertiary: Demo operator / product tester

Needs predictable seeded content, test pantry, simple permissions and onboarding, and a fallback mode when glasses/network/AI are unavailable.

### 2.4 Prioritized user pains

| Pain | Severity | Current workaround | SousLens answer |
|---|---|---|---|
| Recipe not suited to what's available | High | Manual inventory + improvisation | Pantry-aware fit + explicit swaps |
| Video instructions difficult to follow mid-cook | High | Rewind, pause, dirty phone | Stateful audio guidance + step clips |
| Generic AI improvises ungrounded steps | High | Re-read original recipe | Structured recipe + backend oracle |
| Pantry entry too tedious | Medium–high | Manual lists | Voice and photo review/confirm |
| Creator's tacit know-how gets lost | Medium–high | Long unstructured videos | Extracted steps, cues, warnings, timestamped clips |
| No simple way to share adaptations | Medium | Notes/screenshots | Attributed recipe variants |

---

## 3. Product principles

1. **Recipe-first, AI-second.** Start with a human-origin recipe; label any AI changes.
2. **Hands-free where it matters.** The highest-value wearable moments are ingredient checks and step-by-step help while cooking.
3. **Show your work.** Ground coaching in the recipe step, creator notes, and explicit pantry state; cite original step/clip in app.
4. **No silent state changes.** User confirmation for pantry changes, substitutions, publishing, and completing a step.
5. **Ask before making safety-critical assumptions.** Food temperature, allergens, and spoilage require proper verification.
6. **Graceful degradation.** Phone-only, no-glasses, temporary-offline, and no-camera modes must remain useful.
7. **Respect the kitchen.** Short responses, easy repeat/back/next, noise handling, and visible privacy state.

---

## 4. Scope and phased releases

### 4.1 P0 MVP (one polished loop)

**A. Content + community-lite**
- Seeded Discover feed of original public recipes; recipe detail pages; search/filter by title/ingredient; save/unsave.
- Minimal accounts/profile names; creator can create, preview, edit drafts, publish, and unpublish own recipes.
- Structured text recipe authoring: title, photo, description, servings, prep/cook time, ingredients, numbered steps, step-level notes/alerts and optional short clips.
- **Retrace capture slice:** upload an original cooking demonstration (up to 15 min, 200 MB) and request asynchronous AI extraction into an editable draft with timestamped step references. Human review mandatory before publishing. Generate per-step clips where valid timestamps exist; fallback to textual steps if extraction fails.
- Shareable recipe link/deep link; every recipe displays attribution and immutable published-version ID.

**B. Pantry**
- Manually add/edit/delete ingredients.
- Voice-to-text pantry entry using **phone microphone** in P0; parse one or multiple ingredients into tentative pantry items; user confirms.
- Photo pantry scanning via iPhone and/or glasses camera; AI proposes candidate ingredient names; explicit review before save. Do not claim visual quantity/expiry certainty.
- Pantry fit: "can make," "missing items," and "uncertain items" with clear reasons.

**C. Adaptive cooking**
- Ingredient substitutions: suggestions tied to a missing recipe ingredient, with usage amount, adjustment, flavor/texture impact, confidence, and allergy warning when relevant. User approves each swap, generating a **session adaptation**, never overwriting the original.
- Cooking mode on iPhone with current step, previous/next, read aloud, repeat, timer suggestions, and recipe video clips.
- A stateful AI assistant responds to questions about the selected recipe and current step, optionally using a user-requested still frame. Examples: "What does this mean?" "Is this onion cut small enough?" "What if I don't have mirin?"
- Session recovery after app relaunch: recipe/version, approved substitutions, active step, timers and notes restored.

**D. Glasses integration**
- Connect supported Meta glasses through Device Access Toolkit when available.
- Camera frames can be **deliberately captured/selected from live preview** for ingredient recognition or scene questions. Use SDK-supported method available to the testing channel, with no production reliance on experimental standalone high-quality capture.
- Audio instruction output to glasses when standard system Bluetooth audio routing is available.
- Glasses microphone via standard Bluetooth HFP path **only after verifying active route**; otherwise visibly fall back to iPhone microphone. Do not depend on experimental DAT audio-streaming or DAT speech APIs.
- All wearable interaction works without a display. Display is a separate P1 adapter.

**E. Reliability and safety**
- Explicit camera consent, start/stop capture indicator, no passive recording, no default frame retention.
- Safeguards for allergies, raw poultry, heating, hot oil and doneness; user responsibility, thermometer guidance where appropriate.
- Basic auth, private pantry isolation, structured error handling, cost/rate limits, and operational logs without raw photos/audio.

### 4.2 P1 (after P0 passes acceptance tests)

- Follow creators, creator collections, likes or comments (choose at most one initially), richer community feed.
- Publish a **forked recipe variant** with lineage and attribution; ratings on actual successful cooks.
- Creator-guided skill checkpoints with on-demand step verification and confidence thresholds.
- Meta Ray-Ban Display recipe cards and supported hands-free controls (device-specific, gated by current SDK status).
- More robust live voice: interruptions/barge-in, low-latency session reuse and resumption, telemetry on mic routing.
- Recipe import from a URL or user-provided text where technically/legal permitted. No unauthorized download/republication.
- Pantry quantities and multi-item reconciliations, expiry reminders with user-verified dates, grocery list.
- Local caching of media and persistent hands-free mode improvements.

### 4.3 P2 (not part of first build)

- Continuous autonomous scene tracking or auto-advancement; automatic pantry decrement; meal planning/calendar; grocery-store accounts; checkout/delivery; nutrition macros/medical diets; multi-language creator dubbing; follower graph/notifications; monetization; professional creator marketplace; collaborative households; large-scale recommendations; personalization ranking models; food-science verification beyond standard text rules.

### 4.4 What counts as MVP complete

A fresh tester can open a creator's original recipe, scan or speak ingredients into a confirmed pantry, see missing ingredients, accept a safe substitution, begin cooking, receive relevant spoken guidance, ask one visually grounded question, advance through all steps, and finish a session. The same experience is demonstrable phone-only and, for compatible hardware, through Meta glasses camera/audio. A creator can publish an edited AI-extracted recipe from an authorized video.

---

## 5. The five critical user journeys

### J1 — Creator records once, learner can follow later
1. Creator signs in, taps **Create recipe**.
2. Chooses **Write recipe** or **Import my cooking demonstration**.
3. Enters title, dish photo, serving count, optional creator context and key warnings.
4. If video: uploads own recording, receives processing status; AI generates proposed steps, ingredients, skill cues, timestamps and clips.
5. Creator reviews, corrects, adds missing amounts, marks allergens and risky steps, previews the lesson.
6. Creator publishes a numbered immutable version and obtains a deep link.
7. Learner finds recipe through feed or shared link, views creator attribution and source notes.

**Failure:** extraction cannot identify ingredient amount or reliable step boundaries → mark `needs_review`, show editable placeholders, never invent precise quantities as if known.

### J2 — User updates pantry hands-free
1. On **My Pantry**, taps microphone or camera icon.
2. Says "I have chicken thighs, two onions, gochujang and honey" or captures kitchen/fridge/pantry view.
3. AI creates **proposed** items with canonical names, rough amount only if explicitly spoken, source and confidence.
4. User reviews checklist, corrects names/amounts, accepts or rejects individually.
5. Pantry list updates with `last_confirmed_at`; user can edit or delete anytime.

**Failure:** occluded label, unlabeled container, duplicate ingredient, unsupported food → flag `unknown` or match existing item and ask before merging.

### J3 — User finds an achievable recipe
1. Opens recipe → taps **Check my pantry**.
2. App resolves required ingredients/amounts against confirmed pantry.
3. Shows **Available**, **Missing**, **Uncertain**, and **Pantry fit score** with rationale.
4. If missing, proposes substitutions from trusted rules + AI reasoning, *not* unqualified hallucinations.
5. User approves each proposed change and can revert.
6. Session-specific adapted ingredients/instructions preview before **Start cooking**.

**Failure:** no acceptable substitution → keep missing ingredient and suggest a shopping-list item or another recipe.

### J4 — Learner cooks with an assistant
1. Taps **Start cooking** on the selected version.
2. Cooking screen shows step N of M, text, original clip, timers, approved adaptations, **Ask**, **Look**, **Back**, **Next**, **Pause**.
3. Assistant says one concise instruction; learner can ask follow-up by voice/text.
4. If learner says "show me what finely minced means," play source clip if available and explain.
5. If learner says "does this look right?", capture a deliberate camera frame, inspect with VLM, state uncertainty, compare to step cues, and give grounded feedback.
6. Step moves forward only from explicit user's Next action or clear user confirmation, validated by server oracle.
7. End session, offer private note and **Save my changes** (no public fork until P1).

**Failure:** background audio interruption, network drop, glasses disconnect → retain current step; resume via phone, not reset to step 1.

### J5 — Glasses as cooking interface
1. From iPhone, enable **Connect glasses** and explain permissions.
2. App displays status: connected, camera allowed, audio output active, microphone route confirmed or phone fallback.
3. Learner can hear current step through glasses; with verified route, issue spoken commands such as "next," "repeat," "what does sauté mean?"
4. When user asks a scene-based question, app begins a scoped camera preview/capture action, sends selected frame with step context, then stops camera after result unless explicitly continued.
5. If unsupported/disconnected, show nonblocking "Continuing on iPhone" and keep session intact.

---

## 6. Information architecture and screen inventory

Bottom nav (P0): **Explore**, **Saved**, **Pantry**, **Profile**. A floating/current-session entry appears only when cooking.

| Screen | Primary elements | Main actions |
|---|---|---|
| Explore | Seeded recipe cards, search, simple tags | Open, save |
| Recipe detail | Hero photo, creator, ingredient list, steps, warnings, clips, pantry fit | Save, share, check pantry, start |
| Recipe create/edit | Draft fields, ingredient editor, step editor, media, AI extraction review | Save draft, publish |
| My Pantry | Confirmed items, timestamps, capture actions | Add, edit, remove, voice/photo scan |
| Scan review | Candidates with confidence/duplicate warnings | Edit, select, confirm |
| Pantry fit | Available/missing/uncertain, adaptations | Choose substitution, start |
| Cooking | One current step, source clip, timer, mic/camera, controls | Ask, look, back, next, pause/finish |
| Assistant drawer | Grounded conversation, source-step badge, warnings | Repeat, view clip, dismiss |
| Session end | Steps completed, swaps, notes | Save notes, done |
| Glasses connection | Device state, permissions, input/output route | Connect, disconnect, test |
| Profile | Published recipes, saved recipes, account controls | Sign in/out, create, privacy |

### 6.1 UX details

- Cooking layout: high-contrast large type and oversized touch targets, since the phone may be propped at a distance.
- Voice assistant replies generally <20 seconds, ideally 1–3 short sentences unless the user asks for more.
- Speak current step only after explicit start/next/ask; do not chatter continuously.
- No reliance on a wake word for P0: push-to-talk on phone, Bluetooth headset button/verified speech path where feasible; hands-free commands are progressive enhancement.
- Always display which input is active: glasses microphone vs iPhone microphone, and camera active/inactive.
- Offer **Repeat**, **Slower**, **Back**, **Next**, **Stop listening**.
- Timer suggestion never equals automatic timer start; user confirms.
- Voice commands should be robust to kitchen noise and overlap: only final high-confidence commands move a step; low confidence asks for confirmation.
- Empty states must offer "Try the demo recipe" and "Add pantry item".

---

## 7. Functional requirements with testable acceptance criteria

Each row is individually testable. P0 is a release gate; P1/P2 aren't blockers for P0.

### 7.1 Accounts, public recipes, authoring

| ID | Pri | Requirement | Acceptance / observable result |
|---|---|---|---|
| AUTH-01 | P0 | User auth and profile | Tester can sign in/out; private records isolated; backend rejects unauthorized writes. |
| REC-01 | P0 | Browse public feed | 5+ seeded permissioned recipes appear; recipes open by ID and share link. |
| REC-02 | P0 | Search and save | Search title/ingredient; save persists across launch; duplicate save idempotent. |
| REC-03 | P0 | Author structured draft | Creator can add recipe metadata, ingredients, steps, optional clip/tips, and preview. |
| REC-04 | P0 | Publish version | Publishing validates required fields, creates immutable snapshot and increments version. |
| REC-05 | P0 | Creator attribution | Creator is shown on detail and any private adaptations; unpublish hides from feed but preserves lawful prior session references. |
| REC-06 | P0 | Edit drafts; revise published | Editing a published recipe creates draft for a new version, not in-place mutation. |
| CAP-01 | P0 | Own-video upload | Authenticated creator uploads permitted MP4/MOV within configured 15 min / 200 MB limits; rejects unsupported input clearly. |
| CAP-02 | P0 | Asynchronous extraction | UI shows queued/running/review/failed status; worker extracts ingredients, steps, cues, time spans, unknowns. |
| CAP-03 | P0 | Creator verification | AI result is NOT published until creator reviews and approves; missing measures shown as unresolved. |
| CAP-04 | P0 | Clip generation | For valid spans, ffmpeg creates playable step clips linked to source time; failures don't block text recipe. |
| SOC-01 | P1 | Follow/fork | Public variant retains parent recipe/version and attribution; creator can opt out of derivative publishing. |

### 7.2 Pantry + recipe matching

| ID | Pri | Requirement | Acceptance / observable result |
|---|---|---|---|
| PAN-01 | P0 | Manual pantry CRUD | Add/edit/delete normalized ingredient, optional quantity/unit, location and note. |
| PAN-02 | P0 | Spoken batch capture | Spoken "two onions, garlic, chicken" creates tentative candidates; nothing persisted without review. |
| PAN-03 | P0 | Visual capture | User-selected image returns tentative identified ingredient list, evidence, confidence, and unknowns. |
| PAN-04 | P0 | Explicit confirmation | Item-level review and duplicate resolution; rejecting candidate does not change pantry. |
| PAN-05 | P0 | Provenance/freshness | Pantry stores last confirmed, source (manual/voice/image), optional amount and uncertainty. |
| FIT-01 | P0 | Ingredient match | Recipe classified into available/missing/uncertain; exact and normalized synonyms tested. |
| FIT-02 | P0 | Coverage with quantities | Unknown quantity counts as present-but-uncertain when needed amount is specified. |
| FIT-03 | P0 | Transparent fit | No claim "you can make it" if required item is uncertain; show rationale. |
| PAN-06 | P1 | Pantry reconciliation | Repeated scans propose merges/changes; no silent deletion/decrement. |

### 7.3 Substitution and adaptation

| ID | Pri | Requirement | Acceptance / observable result |
|---|---|---|---|
| SUB-01 | P0 | Generate relevant substitutions | Suggestion references missing ingredient, ratio or unknown amount, sensory impact and limitations. |
| SUB-02 | P0 | Allergies and preferences | User-provided restrictions filter/block incompatible suggestions; unclear conflicts prompt explicit caution. |
| SUB-03 | P0 | Human-approved adaptation | Each proposed swap requires approval; no original recipe mutation; can revert. |
| SUB-04 | P0 | Step-aware changes | Adaptation updates relevant cooking-step references for *session*, with AI changes visually distinguished. |
| SUB-05 | P0 | Safe no-match result | If unsuitable swap, say no suitable substitute rather than fabricate one. |
| SUB-06 | P1 | Save attributed variant | Private change set can be turned into creator-attributed public variant after user review. |

### 7.4 Cooking session and assistance

| ID | Pri | Requirement | Acceptance / observable result |
|---|---|---|---|
| COOK-01 | P0 | Start immutable session | Session pins recipe version, substitutions, step 0, and pantry snapshot. |
| COOK-02 | P0 | Deterministic step progression | Next/back/skip work idempotently and honor boundaries; LLM cannot directly mutate step index. |
| COOK-03 | P0 | Grounded Q&A | Answers cite current step, ingredient, or creator note in structured metadata; no invented recipe amounts. |
| COOK-04 | P0 | Voice + text interactions | Typed query always available; phone mic push-to-talk can ask and hear a response. |
| COOK-05 | P0 | Request a visual check | User taps Look or explicitly asks; selected image analyzed in context of step; no unsupported certainty. |
| COOK-06 | P0 | Playback and timers | Original clip (when present), step read-aloud, repeat and user-confirmed basic timers. |
| COOK-07 | P0 | Resume/reconnect | Kill/relaunch or temporary disconnect restores canonical step, adaptations, timer target times. |
| COOK-08 | P0 | Complete + reflection | Session can be completed/abandoned, stores outcome, notes and optional private variation. |
| COOK-09 | P1 | Visual step verification | Model yields `evidence`, `confidence`, `unknowns`; only advises, never auto-advances without policy approval. |
| COOK-10 | P1 | Live speech interruption | Interruption stops output safely, preserves step and transcript, reopens listener. |

### 7.5 Wearables, device fallback, and security

| ID | Pri | Requirement | Acceptance / observable result |
|---|---|---|---|
| WEA-01 | P0 | DAT pairing/session | Connect/disconnect and communicate error states for supported hardware and MockDeviceKit. |
| WEA-02 | P0 | Camera frame on demand | Explicit user-initiated preview/frame extraction can feed Pantry/Look; permission denied yields iPhone fallback. |
| WEA-03 | P0 | Bluetooth audio route | Glasses output works where OS route allows; microphone route is verified; phone fallback explicitly shown. |
| WEA-04 | P0 | No required in-lens UI | Full feature loop works on displayless Ray-Ban Meta and phone-only modes. |
| WEA-05 | P0 | Session continuity | Glasses disconnection never ends/advances/loses cooking session. |
| WEA-06 | P1 | Display UI | Present current step/glance card on supported display glasses once approved/current API verified. |
| PRIV-01 | P0 | Media consent | No capture without explicit permission and visible active state; source recipe video has publishing rights checkbox. |
| PRIV-02 | P0 | Data controls | Delete pantry items, sessions, draft uploads; define cloud retention, user-visible delete flow. |
| SEC-01 | P0 | Authentication/authorization | No cross-user pantry access, no unauthorized author modifications, no exposed provider API key. |
| SEC-02 | P0 | Robust media handling | Enforce content type, size, time, signed URLs, filename sanitation, worker time/memory limits. |

---

## 8. AI-specific product behavior

### 8.1 AI subsystems, separated by responsibility

1. **Recipe Extractor (asynchronous):** original creator video + metadata → candidate structured recipe/step clips. Does not publish.
2. **Pantry Extractor:** speech transcript or photo → tentative normalized ingredient observations. Does not commit.
3. **Matcher:** deterministic normalization + ingredient matching → fit labels and missing list; no LLM needed for core availability decisions.
4. **Substitution Advisor:** pantry, recipe, constraints → ranked, qualified suggestions. Must decline unsafe/poor swaps.
5. **Cooking Coach:** conversational audio/text grounded in pinned recipe version, session overrides, current step, notes and approved observations.
6. **Visual Observer:** single deliberate image + step-specific query → observation, uncertainty, next troubleshooting suggestion. Never certifies safe cooking temperatures.
7. **Step Oracle:** backend policy/state machine validates proposed actions and advances session transactionally.

### 8.2 Extraction outputs

- Separate observed content from inferred content; record `source_start_ms`, `source_end_ms`, `evidence_text` and `confidence` when possible.
- Extract ingredients and quantities only when seen/read/heard reliably. Unknown quantities remain `null` with a review flag.
- Clip times may overlap; no assumption every step can be timestamped reliably.
- Tips/cues distinguish creator-authored, directly-observed and AI-generated explanatory text.
- Writer can reorder steps but must inspect clip references before publish.
- Worker output must validate against schema; malformed model result retries once and otherwise surfaces human-editable partial draft.

### 8.3 Pantry visual inference rules

- Classify visible labeled packages and recognizable produce with calibrated confidence, e.g., >0.85 high, 0.6–0.85 medium, <0.6 unknown. These are initial UX bins, **not statistically calibrated guarantees**.
- Never infer total pantry contents from one image; unseen items remain unknown.
- Do not infer expiration or food safety from appearance alone.
- Do not infer quantity beyond visibly countable items, and mark estimates as such. Ask user to confirm container contents.
- Name resolution: canonical entry + raw recognized label + synonyms (e.g. scallion/green onion); don't collapse distinct allergens or raw vs cooked states.

### 8.4 Substitution policy

Suggestions include: `target_ingredient`, `candidate`, `ratio_or_amount`, `rationale`, `impact_flavor`, `impact_texture`, `adjusted_steps`, `confidence`, `risks`, `requires_user_confirmation`.

Precedence: user-reported allergy > known food safety rule > explicit recipe warnings > pantry presence > preference > culinary creativity. For allergy-critical or medically restricted ingredients, **avoid assuming a substitute is safe** merely from an image or generic recipe knowledge. When unsure, decline or ask the user to check the product label and trusted clinical guidance.

Separate categorical substitution types: close equivalent (e.g., scallions for green onion), acceptable flavor adaptation, structural substitution (changes moisture/leavening), and not recommended. High-risk baking/food-preservation substitutions should be conservative.

### 8.5 Cooking Coach grounding packet

Send only the context needed for current interaction:
- `recipe_id`, `version`, title, servings, original ingredient amounts and units.
- Current step and neighboring step summaries; creator tips, warnings, source clip URL/id.
- Approved substitution overlays and why made.
- Confirmed pantry subset relevant to recipe (not entire kitchen profile).
- Last 5–10 turns of session transcript summary; current timers and user preferences relevant to food.
- User image only when explicitly captured for current action.

**Coach instruction contract:**
- Give the immediate next action or direct answer first.
- Separate "the recipe says" from "my suggestion."
- Never claim to have seen something unless `VisualObserver` supplied actual image evidence.
- Never claim cooking is safe/done from color alone; recommend an appropriate thermometer/verified guidance when relevant.
- If query is outside recipe, say so and answer briefly without changing it.
- Do not directly update pantry, recipe, substitutions, timers or step state. Return structured `proposed_action` that backend/UI can confirm.
- If original step is unclear, ask the user rather than inventing unobserved details.

### 8.6 Step Oracle state machine

States: `created → active ↔ paused → completed | abandoned`. In `active`, `step_index ∈ [0, steps_count - 1]`.

Allowed commands:
- `start`: created → active, step 0.
- `next`: active, advance by 1 after explicit UI action or unambiguous final voice intent; last step requires completion confirmation.
- `back`: active, decrement by 1; at step 0 no-op.
- `jump_to_step`: active, explicit user selection/confirmation; no AI-only jump.
- `pause` / `resume`: preserve step/timers.
- `complete`: only at user request with final confirmation.
- `abandon`: explicit user request.

The LLM may propose `next`, but the backend only commits if `user_confirmed=true`, authenticated actor owns session, request includes an idempotency key and expected `state_revision`, and transition passes policy checks. Conflict returns latest state. **Visual classification alone never advances the step in P0.**

### 8.7 AI failure expectations

- Uncertain observations: "I can't confirm from this angle. Can you bring the camera closer?"
- Model timeout: show current instructions immediately; offer retry.
- Incorrect substitution: user can reject, rollback and report.
- Tool/action parsing failures: do not mutate state.
- Prompt injection in published recipe text or comments: treat all content as untrusted data; no provider keys or system instructions exposed.
- Model switch/feature degradation: typed UI always works and deterministic step progression remains usable.

---

## 9. Technical architecture

### 9.1 Chosen stack

**Client:** SwiftUI, Swift Concurrency, AVFoundation/AVAudioSession, local persistence (SwiftData or small SQLite store for cache), Meta Wearables Device Access Toolkit via Swift Package Manager; optional MockDeviceKit for development.

**Backend:** Python 3.12+, FastAPI, Pydantic v2, SQLAlchemy/asyncpg, Postgres, background extraction worker, FFmpeg/ffprobe, signed object storage, provider adapter for Gemini family models including Gemini Live. Run on existing AWS Lightsail/Caddy/systemd infrastructure if available; managed Postgres/Auth/Storage (e.g., Supabase) is an acceptable speed-oriented default.

**Auth:** Managed Auth with iOS token → FastAPI JWT verification. Server enforces ownership and author identity. Sign in with Apple recommended if implementing third-party consumer login; dev accounts can be email magic links.

**AI:** Gemini structured model for batch extraction/vision/substitutions; Gemini Live for low-latency audio dialogue when stable for the selected model. **Pin model names/config in server environment**, do not hard-code experimental model IDs into business logic. Introduce provider interfaces so fallback models are possible.

**Storage:** Postgres for normalized structured records and event log; object storage for user-consented images, video originals and clips; signed, scoped URLs. Do not put base64 media in database.

**Queue:** Small persistent Postgres jobs table with a single worker and retry/backoff is enough initially; migrate to Redis-backed queue if performance requires it.

### 9.2 Component diagram

```text
          Creator / Learner on iPhone (SwiftUI)
      ┌─────────────────────────────────────────────┐
      │ Explore / Recipe Editor / Pantry / Cooking   │
      │ Local Cache + AVAudioSession + DAT Adapter   │
      └────────────┬─────────────────────┬──────────┘
                   │ HTTPS / WS          │ Wearables DAT + BT audio
                   │                     ▼
                   │              Meta AI glasses
                   │              camera / output / HFP
                   ▼
       ┌─────────────────────────────┐
       │ FastAPI API / Auth / Policy │
       │ Recipe + Pantry + Sessions  │
       │ Step Oracle + AI Adapters   │
       └───────┬─────────┬───────────┘
               │         │
       ┌───────▼───┐  ┌──▼──────────────────┐
       │ Postgres  │  │ Media / jobs worker │
       │ Versions  │  │ FFmpeg + extraction │
       │ Pantry    │  └─────────┬───────────┘
       │ Events    │            │
       └───────────┘       ┌────▼────────────┐
                           │ Object storage │
                           │ originals/clips│
                           └─────────────────┘
                  ┌────────────────────────────┐
                  │ Gemini models / Live API  │
                  │ gated through AI adapters │
                  └────────────────────────────┘
```

### 9.3 Runtime request paths

**Published recipe:** iPhone → FastAPI → Postgres latest public version + signed cover/clip media. Client caches read-only snapshot.

**Creator video:** iPhone requests signed upload → storage → FastAPI creates job → worker ffprobe validates + extracts step candidates → model returns schema → worker ffmpeg renders candidate clips → creator review → publish immutable version.

**Pantry capture:** user action → one image/transcript → FastAPI vision/text extraction → candidate list (ephemeral) → user confirms via REST mutation → Postgres pantry.

**Match/substitute:** deterministic matching reads version + user pantry; optional substitution service generates candidate with typed risks; user accepts to session overlay.

**Cooking:** client creates pinned session → backend stores state → voice/text query uses recipe-grounded context → model returns advice / structured proposal → Step Oracle applies only authenticated, confirmed commands → client fetches latest state.

**Glasses frame:** DAT starts explicit video preview → client selects/compresses frame → POST `/vision/inspect` using ephemeral single request → displays/speaks result → stops visual capture as requested. Camera stream is not directly relayed continuously to model in P0.

**Live audio:** iOS headset/phone AVAudioEngine produces PCM → either short recorded utterances to backend STT/LLM/TTS pipeline (robust P0) or Gemini Live session via backend-issued ephemeral credentials (P1 performance route). If direct Live used, backend remains authoritative for actions. No permanent AI API key on phone.

### 9.4 Meta glasses engineering constraints and fallback

**Verified public documentation on October 15, 2026:** Meta states DAT 1.0 began rolling out September 30, 2026, with camera, audio and other capabilities varying by device. The public GitHub integration docs also mark certain audio streaming, speech, standalone high-quality photo capture, inputs and voice invocation surfaces experimental or gated. Publishing/discovery may be limited to approved channels. Treat source docs as living, not a promise that every advertised capability is permitted in general distribution.

- Supported toolkit devices listed by Meta: Ray-Ban Meta Gen 1/2, Ray-Ban Meta Display, Oakley Meta HSTN, Oakley Meta Vanguard; capabilities vary.
- Start from official iOS `CameraAccess` sample; add `MWDATCore`, `MWDATCamera`, `MWDATMockDevice` as supported by current release. Consult official `AGENTS.md` and docs MCP for exact APIs.
- Set required URL callback, permissions, Bluetooth/local-network/Bonjour/external-accessory declarations according to *current* sample, not copied forever from this PRD.
- Distinguish `DeviceSession` from explicit camera-preview start/stop. On app background/disconnect, stop preview and preserve backend cooking session.
- Use frame extraction from active SDK stream and supported capture APIs. Do not depend on **experimental** standalone photo capture in publicly distributed P0.
- Glasses audio output/mic use iOS audio routing; for mic check `AVAudioSession.currentRoute.inputs` includes Bluetooth HFP before declaring "glasses microphone" active. In camera+HFP scenarios order device/audio setup per current Meta docs; verify after each interruption. If not confirmed, show phone-mic fallback.
- Avoid hardcoded assumptions about in-lens display, independent glasses execution, hands-free wake-word registration, foreground/background access, or guaranteed continuous microphone quality.
- Provide `CameraSource` protocol with `PhoneCameraSource` and `MetaGlassesCameraSource`; `SpeechInput`/`AudioOutput` adapters as separate interfaces.
- Test using Meta MockDeviceKit plus real device for route/timing/heat/battery behavior. Mock device is not substitute for real HFP audio routing tests.

**Reference docs (confirm versions before implementation):**
- DAT product: https://developers.meta.com/wearables/device-access-toolkit/
- DAT FAQ: https://developers.meta.com/wearables/faq/
- Official iOS toolkit: https://github.com/facebook/meta-wearables-dat-ios
- Camera sample: https://github.com/facebook/meta-wearables-dat-ios/tree/main/samples/CameraAccess
- Claude Code toolkit plugin: `claude plugin marketplace add facebook/meta-wearables-dat-ios`, then `claude plugin install mwdat-ios@mwdat-ios-marketplace` if available in your Claude environment.
- Gemini Live: https://ai.google.dev/gemini-api/docs/live-api/capabilities
- Session recovery: https://ai.google.dev/gemini-api/docs/live-api/session-management
- Live auth: https://ai.google.dev/gemini-api/docs/live-api/ephemeral-tokens

### 9.5 Live API practical constraints

- Live audio/video and function-calling features are provider/model/version-specific. Gemini Live docs currently describe audio PCM input, max **1 video frame per second** for realtime video, connection/session lifetime limits, context compression and session resumption. Do not infer that continuous high-FPS camera streams are acceptable directly as Live inputs.
- P0 keeps voice turn-based and visual capture deliberate. P1 can add continuous speech after a proven reliability baseline.
- If Live session reconnects, rebuild authoritative recipe/session context from backend; never let conversation history be the canonical step store.
- External provider response might arrive after the user moved to another step: responses include the `step_revision` they were grounded on; discard or label stale output.

---

## 10. Data model

Use UUID primary keys and UTC timestamps. All owned resources have `owner_user_id` and explicit read/write policy. Row examples below show logical schema, not binding SQL migrations.

| Table | Key fields | Notes |
|---|---|---|
| `users` | id, display_name, created_at, preference_units | Auth provider subject link |
| `recipes` | id, owner_user_id, slug, visibility, title, summary, tags, latest_version_id, published_at | Mutable metadata only |
| `recipe_versions` | id, recipe_id, version_number, servings, prep_minutes, cook_minutes, ingredient_json, step_json, warning_json, source_video_id, created_at | Immutable once published |
| `recipe_media` | id, recipe_id, version_id, media_kind, storage_key, start_ms, end_ms, consent_record_id | Source or step clips |
| `recipe_drafts` | id, owner_user_id, recipe_id_nullable, structured_draft_json, status | Editable incl. AI extraction review |
| `extraction_jobs` | id, owner_user_id, draft_id, original_media_id, status, attempts, error_code, result_json, created_at | Queued/working/review/failed |
| `saves` | user_id, recipe_id, created_at | Composite unique |
| `ingredients` | id, canonical_name, aliases_json, category, allergen_flags | Controlled seed dictionary + aliases |
| `pantry_items` | id, owner_user_id, ingredient_id_nullable, raw_label, normalized_name, quantity_nullable, unit_nullable, storage_location, source, confidence_nullable, last_confirmed_at | No inferred expiry unless verified |
| `pantry_observations` | id, owner_user_id, mode, candidate_json, status, source_image_key_nullable, expires_at | Uncommitted suggestions; short TTL |
| `cooking_sessions` | id, owner_user_id, recipe_version_id, status, step_index, revision, pantry_snapshot_json, adaptation_json, started_at, ended_at | Authoritative session |
| `session_events` | id, session_id, sequence, type, payload_json, idempotency_key, created_at | Append-only, own-user read |
| `session_messages` | id, session_id, role, text, grounded_step_index, grounded_revision, source_refs_json, created_at | Optional retained, user-deletable |
| `timers` | id, session_id, step_index, label, target_at, status | Absolute deadline survives restart |
| `media_consents` | id, owner_user_id, content_id, consent_type, captured_at, withdrawn_at | Creator confirms rights |
| `feedback` | id, user_id, session_id_nullable, category, severity, details | Optional QA feedback |

### 10.1 Canonical recipe JSON (illustrative)

```json
{
  "schema_version": "1.0",
  "recipe_id": "uuid",
  "recipe_version_id": "uuid",
  "title": "Spicy Gochujang Chicken Thighs",
  "creator_id": "uuid",
  "servings": 4,
  "prep_minutes": 15,
  "cook_minutes": 25,
  "ingredients": [
    {"id": "ing-1", "name": "boneless chicken thighs", "quantity": 3, "unit": "lb", "optional": false, "preparation": "cut into pieces"},
    {"id": "ing-2", "name": "gochujang", "quantity": 3, "unit": "tbsp", "optional": false}
  ],
  "steps": [
    {
      "id": "step-1",
      "order": 0,
      "instruction": "Combine the marinade ingredients in a large bowl.",
      "ingredient_refs": ["ing-2"],
      "estimated_minutes": 5,
      "success_cues": ["Sauce is homogeneous before coating chicken"],
      "warnings": [],
      "source_clip_id": "clip-1",
      "source_start_ms": 28000,
      "source_end_ms": 72000,
      "evidence_origin": "creator_reviewed"
    }
  ],
  "dietary_warnings": [],
  "published_at": "2026-10-15T00:00:00Z"
}
```

**Versioning rule:** `recipe_versions` is append-only after publication. Active cooking session references a specific version forever, even if the creator publishes v2. Deleting public visibility must not expose archived private source video; policy defines whether session retains instructional text only.

### 10.2 Pantry observation JSON

```json
{
  "observation_id": "uuid",
  "mode": "photo",
  "candidates": [
    {"raw_label": "Gochujang", "canonical_name": "gochujang", "quantity": null,
     "unit": null, "confidence": 0.91, "evidence": "package label", "action": "add"},
    {"raw_label": "unlabeled jar", "canonical_name": null, "quantity": null,
     "unit": null, "confidence": 0.17, "evidence": "contents not identifiable", "action": "ignore"}
  ],
  "requires_confirmation": true
}
```

### 10.3 Cooking session JSON

```json
{
  "id": "uuid",
  "recipe_version_id": "uuid",
  "status": "active",
  "step_index": 2,
  "revision": 7,
  "approved_substitutions": [
    {"ingredient_id": "ing-3", "replacement": "rice vinegar + small amount of sugar",
     "reason": "mirin unavailable", "user_approved_at": "2026-10-15T20:01:00Z"}
  ],
  "active_timers": [{"id": "uuid", "label": "simmer", "target_at": "2026-10-15T20:12:00Z"}]
}
```

---

## 11. API surface and contracts

REST under `/v1`; authenticated endpoints require bearer token. `POST/PATCH` that modify sessions also accept `Idempotency-Key`. Long-running AI actions are asynchronous where possible. All errors return `{error: {code, message, retryable, correlation_id}}`.

| Method | Path | Purpose | Response |
|---|---|---|---|
| GET | `/recipes?query=&tag=&cursor=` | Public discover/search | page of cards |
| GET | `/recipes/{id}` | Detail with current published version | recipe + media refs |
| POST | `/recipes/drafts` | Create authoring draft | draft |
| PATCH | `/recipes/drafts/{id}` | Save draft fields | draft |
| POST | `/recipes/drafts/{id}/publish` | Creator-reviewed publish | recipe_version |
| POST | `/recipes/{id}/save` | Save | saved status |
| DELETE | `/recipes/{id}/save` | Unsave | saved status |
| POST | `/media/upload-intents` | Signed upload, constraints | upload URL + media ID |
| POST | `/extractions` | Start video extraction | job ID/status |
| GET | `/extractions/{id}` | Poll progress/results | status + proposed draft |
| GET | `/pantry` | Pantry list | items |
| POST | `/pantry` | Manually add/confirm selected candidates | items |
| PATCH | `/pantry/{id}` | Edit quantity/name | item |
| DELETE | `/pantry/{id}` | Remove | 204 |
| POST | `/pantry/observations` | Analyze photo or transcript, no commit | candidates |
| POST | `/recipes/{version_id}/fit` | Match user pantry | available/missing/uncertain |
| POST | `/substitutions/suggest` | Suggestions for missing ingredient | candidates with risks |
| POST | `/sessions` | Pin recipe version and adaptations | session |
| GET | `/sessions/{id}` | Resume canonical state | session |
| POST | `/sessions/{id}/commands` | Oracle step/pause/finish/timer commands | updated session |
| POST | `/sessions/{id}/ask` | Typed/short-audio grounded question | answer, source_refs, proposals |
| POST | `/sessions/{id}/inspect` | Visual observation for current step | findings/uncertainty |
| POST | `/sessions/{id}/notes` | Private reflections | note |
| DELETE | `/sessions/{id}` | Delete session per retention policy | 204 |
| POST | `/ai/live-token` | Short-lived Gemini Live credential (if enabled) | expiry/constraints |
| GET | `/me/data-export` | Minimal user data export (P1) | export job |

### 11.1 Canonical command contract

```json
{
  "command": "next",
  "expected_revision": 7,
  "user_confirmed": true,
  "client_source": "ios_button",
  "metadata": {}
}
```

Response success: `200` canonical session with `revision=8`. Duplicate idempotency key: identical `200`, no second event. Stale expected revision: `409 STATE_CONFLICT` with latest canonical state. Unconfirmed LLM proposal: `422 CONFIRMATION_REQUIRED`; unauthorized session access: `404` or `403` without leaking metadata.

### 11.2 AI inspect contract

Input: `session_id`, `grounded_revision`, user query, scoped photo media/bytes with MIME and max size, optional capture timestamp. Output:

```json
{
  "observation": "The onion pieces appear uneven in size.",
  "step_alignment": "The recipe asks for a fine dice.",
  "confidence": "medium",
  "limitations": ["The image does not show every onion piece."],
  "suggested_action": "Chop the largest pieces a little smaller.",
  "food_safety_certified": false,
  "grounded_revision": 7,
  "recommended_step_change": null
}
```

If state changed during vision processing, client shows a "Based on previous step" badge and never modifies current step.

---

## 12. Matching, substitutions and deterministic business rules

### 12.1 Matching algorithm (P0)

1. Normalize ingredient names with synonyms (casefold, singular/plural, relevant aliases).
2. Preserve ingredient qualifiers that affect substitution: fresh/dried, raw/cooked, sweetened/unsweetened, allergen identity.
3. Resolve against user-confirmed pantry; no candidate observation counts as present before confirmation.
4. For each required recipe item assign:
   - `available`: normalized match present and sufficient **verified** quantity or recipe item is qualitative.
   - `uncertain`: matched item but quantity unknown, old observation, unclear preparation, or ambiguous alias.
   - `missing`: no compatible pantry item.
   - `optional_missing`: optional ingredient absent.
5. Coverage score for sorting only: weighted required ingredients satisfied / required ingredient count. **Never equate score with guaranteed ability to cook.**
6. Show computed explanation per ingredient, not just numeric score.

### 12.2 Unit handling

- Normalize standard volume/mass/count units for comparison with supported conversion tables.
- Do not convert mass to volume without density known for ingredient; mark uncertain.
- Keep original quantities displayed and conversion provenance attached.
- When recipe changes serving count, scale straightforward amounts but warn for season-to-taste, time, pans and some baking ingredients.

### 12.3 Substitution ranking

Prefer vetted small seed substitution rules for demo recipes; then AI proposes culinary alternatives constrained by context. Rank on ingredient function, flavor, texture, availability, dietary flags, and original recipe intent. Show "Not an exact match" when appropriate. For Korean recipes, distinguish gochujang (fermented paste) vs gochugaru (pepper flakes); don't treat them as equivalent automatically.

---

## 13. Safety, trust, privacy and compliance

### 13.1 Food safety guardrails (hard requirements)

- Never approve meat, poultry, fish or eggs as safely cooked solely from a photo; use a calibrated food thermometer and appropriate verified food-safety guidance.
- Warn that AI cannot verify microbial contamination, cross-contamination, unlabeled allergens, expiry, or proper preservation visually.
- No automatic instruction to taste raw batter with eggs, raw meat marinade, or contaminated surfaces.
- For high-heat/frying/knife handling: concise caution, avoid distracting continuous voice prompts.
- Do not provide definitive medical advice for allergies; require package-label verification for ingredient substitution.
- For user-reported severe allergy, avoid "safe for you" claims. Recommend human verification of labels and facilities.
- If model guidance conflicts with original creator warning or a safety rule, deterministic safety rule wins and user sees why.

### 13.2 Privacy and permissions

- Pantry photos can reveal home interiors and household data; capture is user-initiated, provide a preview, avoid persistent storage unless explicit opt-in.
- Camera and microphone permission requests explain purpose immediately before relevant feature. Recording indicator always visible on app; comply with Meta hardware indicators and policy.
- Default retention for transient analysis images: delete immediately after processing, with hard expiry (target ≤24 hours for retries). Never retain continuous raw video frames from cooking sessions by default.
- Creator-uploaded original videos stored until creator deletes them; per-step public clips only after creator approved publishing.
- Personal pantry and session details are private; public recipes are separate security domain.
- Encryption in transit (TLS) and at rest; signed, short-lived object URLs; minimal operational logs; no raw model prompts containing user images in analytics.
- Opt out of model-provider training when provider contract/options allow; transparently disclose third-party AI processing and applicable policy.
- User can delete private pantry/session data and uploaded creator originals; handle deletion from storage and database with audit logging.
- If recording other people or their voices, require appropriate permission and provide guidance about local recording laws.

### 13.3 Security model

- Enforce authorization server-side on every resource; frontend user IDs are not trusted.
- Strong validation of upload URL targets, MIME/size, video duration; reject non-media bytes; process in worker sandbox with timeouts.
- Defend against prompt injection in recipe text, captions or images: system policy and actions are separate from untrusted creator content; tool calls are structured and whitelisted.
- Secret keys exist on backend only; ephemeral model tokens issued scoped/short lived.
- Apply request limits (e.g., daily extraction/vision caps) and cost quotas per demo user; prevent denial-of-wallet.
- Use storage bucket isolation, row-level security if using Supabase directly, and server-side ownership checks even with RLS.
- If third-party social recipe import later added, honor licenses, attribution, takedowns, and content provenance.

### 13.4 AI transparency

User-facing labels: `Creator instructions`, `AI-extracted, creator-verified`, `AI suggested adaptation`, `Visual estimate — not verified`. Confidence is qualitative unless statistically calibrated. Make source clip and original recipe one tap away.

---

## 14. Non-functional requirements and operational targets

All numbers below are **engineering targets for prototype acceptance**, not externally verified benchmarks.

| Dimension | Target / rule |
|---|---|
| Recipe browse | p95 API response < 800 ms in test environment excluding first image transfer |
| Pantry matching | p95 < 600 ms for ≤200 pantry items and ≤40 recipe ingredients |
| Step command | p95 < 500 ms and transactionally correct under retry |
| Voice assistant | first useful text/audio feedback ideally <3 s for common follow-up on good network; show working state earlier |
| On-demand vision | target <8 s p95 on test network; timeout at 15 s with retry |
| Video extraction | asynchronous, show progress; target 15-min source processed within few minutes depending model and encoding, not a blocking UI call |
| Session durability | 0 lost canonical step transitions in restart/poor-network test suite |
| Audio | ensure spoken instruction route is explicitly tested on supported hardware, fallback always works |
| Camera | no capture before user activation and permission; no lingering stream after stop/background |
| Accessibility | Dynamic Type, VoiceOver descriptions, captions/transcript for spoken content, minimum 44pt tap targets |
| Offline | cached recipe can be viewed and manually progressed; AI feature unavailable with clear messaging; queue notes locally if easy |
| Observability | structured logs, request/job IDs, error codes, metrics; exclude photo/audio payloads |
| Cost controls | per-user daily AI call/video-minute quotas, image downsampling, capped session duration, storage cleanup |
| Platform | iOS min version matched to current DAT sample (official docs currently indicate iOS 17.2+); exact build Xcode/Swift versions verified before coding |

### 14.1 Event instrumentation

Track with privacy-aware event names and no raw content:
`recipe_viewed`, `recipe_saved`, `draft_created`, `extraction_requested`, `extraction_reviewed`, `recipe_published`, `pantry_capture_started`, `pantry_candidates_reviewed`, `pantry_items_confirmed`, `recipe_fit_viewed`, `substitution_suggested`, `substitution_approved`, `session_started`, `step_advanced`, `visual_inspection_requested`, `session_completed`, `glasses_connected`, `glasses_audio_route_fallback`, `ai_error`, `safety_warning_shown`.

---

## 15. Evaluation, KPIs and demo success

### 15.1 North-star qualitative result

A test cook finishes a dish using a recipe from another person **without repeatedly rewatching the entire video or manually rewriting the ingredient list**.

### 15.2 Pilot metrics (targets to validate, not predictions)

- **Activation:** ≥70% of invited testers successfully view, save and start an eligible recipe.
- **Pantry utility:** ≥80% of the 30-item ingredient identification benchmark is correct *after review*; measure raw suggestion precision/recall separately and report unknowns.
- **Instruction completion:** ≥75% of testers who start a designated simple recipe reach session complete; record abandonment reasons.
- **Grounding:** ≥95% of sampled coach responses are consistent with pinned recipe/adaptations; zero silent step jumps.
- **Safety:** zero claims that visual appearance alone proves safe cooking, and zero automatic application of allergy-risky substitutions.
- **Wearable robustness:** no loss of step state across 10 induced disconnect/reconnect cycles.
- **Creator conversion:** 3 first-time creators can edit/publish extracted draft from their own recording, with subjective rating of editing burden.

### 15.3 Research plan

Recruit 5–10 test users across novice/intermediate levels; 2–3 creators. Observe at least 5 end-to-end cooking sessions. Measure actual moments users touch phone, need to repeat instructions, distrust substitutions, need visual guidance, and leave app. Follow a script but note emergent behavior. Ask whether they would *repeat* cooking with SousLens, not only whether demo looked impressive.

### 15.4 Demonstration script (portfolio)

1. Creator publishes 1–3 minute original clip showing gochujang chicken preparation; AI extracts steps/clips, creator edits and publishes.
2. Learner opens public recipe on phone; uses glasses camera to inspect visible pantry items, reviews detected gochujang/chicken/onion/honey, and adds mirin as missing.
3. App presents a qualified substitution for mirin with a flavor-impact explanation; learner explicitly accepts.
4. Learner starts cooking. Audio instructs step one from the creator recipe.
5. Learner asks "How finely should I chop these onions?" and uses deliberate glasses frame; assistant connects observation to the original step/clip.
6. Learner says/taps "next"; backend advances. Simulate glasses disconnect; iPhone displays the same step.
7. Learner finishes and saves a private note explaining how the variation tasted.

**Demo honesty:** If glasses mic is routed to phone or a feature requires a developer channel, state that on screen. Never imply autonomous pan/food safety detection.

---

## 16. Delivery plan for Claude Code (vertical slices)

No time promises; sequence is dependency-based. Don't start slice N+1 until the prior slice's demo and tests pass.

### Slice 0 — Repo and architecture proof

- Create iOS SwiftUI shell, FastAPI health route, Postgres schema/migrations, auth stub or real dev auth, `.env.example`, scripts, CI checks, a sample seeded recipe.
- Add provider interfaces and `MockAIProvider` so core UI works without paid inference.
- Unit tests for models, state machine and endpoints; README setup and local run.
- **Gate:** launch simulator → open seeded recipe; API returns it; backend and client tests run.

### Slice 1 — Browse, author, publish, share

- Recipe list/detail, search, save, creator editor, draft preview, immutable publish/version, direct link.
- Seed 5 recipes; include one that resembles a realistic cooking tutorial with explicit skill cues.
- **Gate:** edit/publish v1; edit again yields v2; existing v1 cooking references unchanged.

### Slice 2 — Pantry capture and fit

- Manual pantry, transcript parser, iPhone photo capture, candidate review, normalization/matching, visible fit screen.
- Cover aliases, duplicates, unknown quantity and blurry image.
- **Gate:** spoken multi-item input and one image each produce reviewable candidates, no silent writes.

### Slice 3 — Substitutions and cooking engine

- Deterministic matcher, substitution advisor, accept/revert overlay; backend session state machine, step UI, timer and resume.
- Start with typed Q&A, grounding citations, mocked AI. Add model provider after deterministic tests.
- **Gate:** complete one recipe with accepted substitution, relaunch recovery, and idempotent step changes.

### Slice 4 — Real voice and vision

- Phone microphone/transcription and spoken playback; single-photo visual inspect; AI safety/uncertainty guardrails, timeouts and replayable test fixtures.
- **Gate:** ask a question about one step and get a sourced response; inspect one frame and receive appropriately uncertain coaching.

### Slice 5 — Retrace expert capture

- Video upload signed URL, extraction job, status polling, schema validation, review, ffmpeg clips, creator publish.
- **Gate:** creator uploads *own* source, corrects AI draft and plays two clips from published recipe; failure yields editable draft.

### Slice 6 — Meta glasses integration

- Install DAT official plugin/sample; device registration; device state + camera preview; extract selected frame through `CameraSource`; connect Bluetooth audio with route validation, iPhone fallback; negative tests and MockDeviceKit.
- **Gate:** hardware camera is used for the same pantry/inspection service as iPhone; no session loss on disconnect; no false "glasses mic active" UI.

### Slice 7 — Hardening and portfolio demo

- Real-device tests, 5-user pilot, privacy cleanup, cost guards, graceful permissions, error-state UI, export short demo video, README architecture/limitations.
- **Gate:** entire Section 15 demo script works with truthful feature labels and tests green.

### 16.1 Suggested repository layout

```text
souslens/
├── README.md
├── PRD.md                      # This file
├── CLAUDE.md                   # Execution constraints/checklist
├── .env.example
├── ios/
│   └── SousLens/
│       ├── App/
│       ├── Features/{Explore,Recipe,Creator,Pantry,Cooking,Profile}/
│       ├── Models/
│       ├── Services/{API,Auth,Audio,Camera,Glasses}/
│       ├── Persistence/
│       └── Tests/
├── backend/
│   ├── app/
│   │   ├── api/v1/
│   │   ├── core/{config,security,errors}/
│   │   ├── db/{models,migrations}/
│   │   ├── domains/{recipes,pantry,matching,substitutions,sessions}/
│   │   ├── ai/{providers,extractor,coach,observer}/
│   │   ├── media/{upload,clips}/
│   │   └── workers/
│   ├── tests/{unit,integration,evaluation}/
│   ├── pyproject.toml
│   └── Dockerfile
├── fixtures/
│   ├── seeded_recipes/
│   ├── pantry_images/           # Permissioned local fixture images only
│   └── expected_outputs/
└── docs/{architecture,decisions,evaluation,privacy}/
```

### 16.2 Claude Code operating protocol

- First read PRD completely; create `docs/implementation-plan.md` mapping each P0 requirement to files and tests.
- Build **Slice 0 only** first, unless explicitly told to continue; no monolithic multi-slice implementation in one untested burst.
- Before each slice, summarize architecture impacts and test plan; after the slice, document what actually runs, tests, deviations, SDK limitations, and next slice.
- Prefer existing Retrace code **if present in local repo** but inspect interfaces and licenses rather than assuming a codebase exists.
- Keep one provider adapter per AI responsibility, typed Pydantic schemas, tests with mock provider, and strongly typed Swift DTOs.
- Any change to this PRD should be proposed as a diff in an ADR, not silently rewritten to rationalize implementation.
- Don't install experimental API dependencies in the core business module; feature-gate and mock them.
- Never place raw API keys, personal media, or live user data in git, screenshots, logs, or tests.

---

## 17. Test plan and acceptance scenarios

### 17.1 Unit tests

- Normalize `green onion` = `scallion` but do not collapse `gochujang` and `gochugaru`.
- Matching missing/maybe-present/available with quantity-known and quantity-unknown cases.
- Idempotent save and session Next requests; revision conflict handling.
- Immutable recipe version on publish/edit.
- Substitution rejects known user-reported allergen; `cannot_substitute` path.
- Timer state persists by `target_at` rather than only local countdown seconds.
- Media source timestamp range validation and clip generation when start/end valid.
- No backend update for unconfirmed pantry candidate or AI-proposed step.

### 17.2 Integration scenarios

1. **Voice pantry:** "I have half an onion, 3 pounds of chicken, gochujang" → candidates contain names/amounts; confirmation adds only selected.
2. **Photo pantry:** blurred/missing-label jar → uncertain, not authoritative.
3. **Quantity mismatch:** user has `1 egg`; recipe requires `3 eggs` → not marked fully available.
4. **Unavailable substitute:** missing a safety-critical ingredient → no confident suggestion.
5. **Recipe update during session:** creator publishes v2; active session remains v1.
6. **Wrong step:** coach answer from old step returns revision and is labeled stale after Next.
7. **Mid-session force quit:** restore step index, overlay and timer.
8. **Repeat Next retry:** same idempotency key advances only once.
9. **Video parse failure:** creator gets editable draft/error, no misleading published content.
10. **Meta disconnect:** stop capture; phone resumes same session without losing transcript or step.
11. **Audio-route failure:** UI says "Using iPhone microphone" rather than claiming glasses mic.
12. **Privacy:** nonowner cannot access pantry or unpublished video through guessed URLs.
13. **Unsafe image question:** "Is this chicken definitely cooked?" → model cannot certify from photo; advises verifying temperature appropriately.
14. **Creator rights:** upload/publish flow requires creator to affirm rights to original video and media.

### 17.3 Evaluation fixtures

- 10 original recipe fixtures, representing sauces, simple sauté, soup, no-cook dish, and one baking recipe.
- 30 ingredient photo fixtures across labeled packs, produce, occluded objects and unknown containers, all permissioned.
- 15 voice transcript fixtures with synonyms, quantities, corrections and noise artifacts.
- 20 substitution cases including 5 no-replacement/unsafe cases.
- 30 step-QA cases with known answers/unknowns and 10 images where the correct response is uncertainty.
- Tests must report precision/recall/calibration on *raw AI output*, not just user-corrected final pantry records.

---

## 18. Risks, assumptions and mitigations

| Risk | Likelihood / impact | Mitigation / decision |
|---|---|---|
| Meta APIs unavailable for production or changed | High / high | iOS-first, DAT adapter, explicit device feature gates, developer-mode demo permitted |
| Glasses mic unreliable while video active | High / medium | AVAudioSession HFP route verification, sequence camera/audio setup, fallback phone mic |
| AI recipe extraction invents amounts | Medium / high | unknown quantity fields + creator review mandatory; source evidence |
| AI visual feedback overconfident | High / high | on-demand, uncertainty contract, no unsafe food safety certification |
| Pantry maintenance burden | High / medium | fast voice/photo review; narrow demo pantry; later scan reconciliation |
| Slow/expensive inference | Medium / high | on-demand images, caching, short transcripts, limits, mock mode |
| Cold-start social feed | High / medium | seeded original recipes + share links; no ranking engine |
| Creator copyright/media rights | Medium / high | only creator-permissioned content; explicit rights attestation + deletion |
| Too many features for solo developer | High / high | strict vertical slices and P0 gates; no P1 social features before full loop works |
| Cooking distractions / safety | Medium / high | concise voice turns, timers acknowledged, warning categories, no control of appliances |
| Device heat/battery and frame quality | Medium / medium | short user-driven capture windows, adaptive resolution, device tests |

---

## 19. Open questions and default decisions

These do not block Slice 0. Defaults below are authoritative until changed by the product owner.

| Question | Default |
|---|---|
| Is this more social platform or AI cooking tutor? | **AI cooking tutor anchored in creator-shared recipes**. Social graph later. |
| Can AI generate entire recipes without creators? | No as primary flow; optional sandbox later. |
| Can users upload external TikTok/Instagram cooking videos? | Not in P0. Only original/authorized video. |
| Should pantry images be stored? | No by default; transient for inference then delete; user opts in to permanent storage if future feature requires. |
| Does pantry auto-decrement after cooking? | No; suggest review later. |
| Can AI automatically verify and advance cooking steps? | No for P0; P1 visual verification remains advisory and explicitly confirmed. |
| What is the first content vertical? | 5–10 simple recipes, including Korean home cooking. Do not specialize exclusively in Korean food until demand tested. |
| Do we support Meta glasses without a display? | Yes, baseline; display cards are separate later feature. |
| What if glasses don't connect? | Full phone-only session; never block cooking. |
| Which AI model? | Provider configuration selected at implementation; preserve interfaces; Gemini family favored for Retrace code reuse. |
| How much social interaction? | P0 feed/save/share, P1 follow/fork/comments. |
| Is real-time visual video sent continuously? | No P0; single deliberate frame requests. |
| What should be shown in demo? | Honest end-to-end source recipe → pantry → substitution → guided execution, with optional glasses. |

---

## 20. Release gates and definition of done

### Gate A — Functionality

Every P0 requirement has at least one test, a reachable UI flow, and a documented fallback. There is at least one published AI-extracted recipe with reviewed source clips, one pantry capture, one substitution, one cooking session, and one glasses camera/audio test.

### Gate B — Correctness

No silent changes to published recipes, pantry or current step. Typed schemas validate model outputs. Sessions survive restart, and concurrent writes produce one canonical result.

### Gate C — Trust

Visible media consent, data deletion routes, authorship attribution, explicit AI labeling, food safety messages, and honest confidence/mic-route displays are present.

### Gate D — Engineering quality

Project can be installed from README, `.env.example` lists keys without secrets, unit/integration checks pass, backend serves seeded demo, simulator runs, and real-hardware limitations are documented.

### Gate E — Portfolio-readiness

Record a short end-to-end demo and architecture walkthrough. Explain technical tradeoffs: use of structured procedures, visual grounding, stateful progression, sparse camera capture, glasses SDK limits, and explicit uncertainty.

---

## 21. Competitive landscape (context, not implementation dependency)

- **FORK'D / Fond:** imported recipes and steps through glasses. SousLens emphasizes source-grounded interactive learning and kitchen adaptation.
- **Glutt:** pantry-aware AI chef and audio wearable experiences. SousLens differentiates by creator-demonstration → structured steps/clips → grounded feedback.
- **Cooklist / SuperCook:** inventory-driven matching. SousLens uses pantry data to teach a *selected creator's recipe*, not only search a recipe database.
- **Samsung Food / Cookpad / NYT Cooking:** strong recipes/community/editorial content. SousLens competes on instructional continuity and personalized context, not catalog size.

Do not claim these are absent features in competitors without checking current live offerings at launch. Differentiation is a **product hypothesis**, not proven market ownership.

---

## 22. Source-of-truth hierarchy and change management

1. User's direct future instructions take precedence.
2. This PRD's explicit P0 functionality and safety rules.
3. Versioned, creator-approved recipe instructions and current session overlay.
4. Current official Meta/Google SDK reference for API syntax, capabilities and release restrictions.
5. Implementation ADRs and verified code tests.
6. AI-generated guesses or demo assumptions (never authoritative).

Keep a `docs/decisions/` directory. When an SDK imposes a hard blocker, document impact, implement the smallest functional phone fallback, and surface deviation instead of fabricating an API.

---

## Appendix A. Minimal example coach output contract

```json
{
  "answer_text": "The creator's current step asks for a fine dice. Some pieces in the image look larger, so chop those a little smaller. I can't judge all pieces from this angle.",
  "grounding": [
    {"type": "recipe_step", "id": "step-3"},
    {"type": "visual_observation", "id": "observation-uuid"}
  ],
  "grounded_session_revision": 7,
  "uncertainty": "medium",
  "safety_notice": null,
  "proposed_action": null,
  "requires_confirmation": false
}
```

## Appendix B. Proposed demo seed recipes

Create or license content rather than importing without permission:
- Gochujang chicken thighs (demonstrates marinade/substitutions)
- Kimchi fried rice (pantry matching and optional toppings)
- Egg-and-tomato stir fry (visual texture cue)
- Simple pasta with garlic (timers and "al dente" cue)
- Quick cucumber salad (no-heat beginner recipe)

Each should have at least 5 structured steps, one creator note, an optional warning, and (for two recipes) one step clip.

## Appendix C. Explicitly excluded deceptive demo shortcuts

- Do not claim a glasses mic is active if audio actually comes from the iPhone.
- Do not simulate model-identified ingredients as if they were detected from a real live frame without disclosing demo mode.
- Do not imply a glass lens/display exists on non-display glasses.
- Do not claim a camera can verify safe poultry doneness.
- Do not call a system autonomous if each state change requires a user confirmation.
- Do not silently save third-party creator media to the public feed.

**End of PRD v1.0**
