# SousLens — Feasibility & Scoping

> Wearable-first cooking co-pilot. Built by forking Retrace's capture/coaching architecture and adding the cooking-specific layer (inventory, substitutions, taste profile, recipe ingest) plus the App Store-required identity/privacy stack Retrace deliberately skipped as a hackathon project.

---

## 1. Retrace today — the inheritance audit

Three repos under `xrcc-retrace`:

| Repo | State | What it is |
|---|---|---|
| `retrace-ios` (also `dat-ios-test` mirror) | Live, TestFlight-shipping | SwiftUI iPhone client, forked from Meta's `CameraAccess` DAT-SDK sample, Bundle ID `com.xrcc.retrace.ios.v1`, signed via Fastlane match + GitHub Actions on `v*` tag |
| `main-local-server-test` | Live, deployed to `https://retracexrcc.duckdns.org` (Lightsail, Caddy, systemd) | FastAPI control plane + Gemini orchestration. SQLite (WAL), Bonjour, in-memory sessions |
| `main-server` | Empty (README only) | Production server placeholder, never built |

### What Retrace already does (high reuse for SousLens)

- **Two capture transports** — Ray-Ban Meta glasses via DAT SDK 0.6, **or** iPhone via `AVCaptureSession`. `CaptureTransport` enum is per-session, end-to-end. `MockDeviceKit` lets the whole app run without hardware.
- **Expert capture → structured SOP pipeline**: video → ffprobe → Gemini Files API → Gemini 2.5 Pro structured-output → ffmpeg per-step clips. Tolerates per-step ffmpeg failures (`completed_partial`).
- **Direct Gemini Live coaching** with full wire-protocol handling (binary-frame JSON sniffing, `setupComplete` gate, server-VAD barge-in, function-call interception).
- **Indefinite session length** — context compression (100k → 40k) + `sessionResumptionUpdate.new_handle` + handle-baked ephemeral tokens. *Critical for cooking*, where sessions run 30–90 min.
- **Ephemeral tokens**: API key never on the phone, locked to model+prompt+tools+voice+compression+resumption.
- **Tool-call dispatcher** (shared between Learner + Troubleshoot) — `advance_step`, `get_reference_clip`, `go_to_step`. Easy to extend.
- **Troubleshoot mode**: `identify_product → confirm → search_procedures → web_search_for_fix (Gemini Pro + GoogleSearch grounding) → handoff_to_learner`. The web-grounded "no procedure exists, synthesize one with cited URLs" pattern is **directly transferable** to "no recipe with these ingredients, synthesize one."
- **PDF manual ingest** (`/api/expert/manuals/upload`): structured-output extraction over PDFs, rasterized step page → PNG written into `step.clip_url`. **Repurposable for cookbook PDFs verbatim.**
- **Hand tracking + Ray-Ban HUD design system** (square 600×600 lens, hover-then-select, recede-and-arrive overlays, hold-to-confirm).
- **Industrial design system** (`design.md`) — monochrome Ink scale + Hazard yellow. SousLens needs a different visual identity, but the *tokens-first* approach is reusable.
- **TestFlight CI**: tag `v*` → Fastlane match + GitHub Actions → ASC build in 12–20 min. Already solved the MediaPipeTasksVision Info.plist patch + signing setup.

### What Retrace doesn't have (must-build for SousLens)

| Gap | Why it matters for App Store |
|---|---|
| **No auth** — confirmed: `grep` for `current_user` / `jwt` / `oauth` returns zero hits | App Store distribution to consumers requires user accounts to satisfy data-deletion + privacy-policy obligations |
| **No per-user data scoping** — every procedure is global, anyone on the LAN/cloud sees all | Required for personal recipes + pantry + taste profile |
| **No privacy posture** — server stores procedures + uploaded videos forever, no deletion API at user grain | Apple privacy nutrition labels + GDPR/CCPA require explicit data lifecycle |
| **No PII boundary** — kitchen scans = inside the home; recipes = family heirlooms. Currently no encryption-at-rest, no field-level scoping | "Privacy-first" claim must be defensible |
| **No URL-based ingest** — only multipart upload of files the user already has on disk | Required for the "ingest YouTube Shorts" feature |
| **No taste profile / recommendation engine** — Discover is a flat list | Required for the "personalized homepage" |
| **No inventory scan** — vision is only used during cooking, not before | Required for inventory-first suggestions + substitutions |
| **In-memory sessions** (`dict` in `services/session.py`) | Fine for hackathon; needs DB persistence for an app that survives a server restart |
| **SQLite single-file** | Won't scale past a few hundred users; need Postgres before public launch |

---

## 2. SousLens architecture — proposed

```
   iPhone / Glasses                   Phone (SousLens iOS)              Backend (SousLens server)
 ┌────────────────────┐          ┌──────────────────────────┐       ┌───────────────────────────┐
 │ Camera (counter,   │          │ Capture orchestrator     │       │ Identity (Apple + Google) │
 │ fridge, hands)     │ ───────► │ Inventory scan (on-dev)  │ REST  │ Recipe ingest pipeline    │
 │ Mic                │          │ Recipe capture (reuse)   │ ◄────►│ Pantry + taste profile    │
 │ Voice, gaze, gesture          │ Coaching orchestrator    │       │ Substitution synthesizer  │
 └────────────────────┘          │ Pantry sync (delta)      │       │ YouTube transcript ingest │
                                 │ Taste profile (local)    │       │ Token minting (reuse)     │
                                 └────────┬─────────────────┘       └───────────┬───────────────┘
                                          │                                     │
                                          │  direct WebSocket                   │  Gemini Files API
                                          │  (BidiGenerateContentConstrained)   │  + Pro REST + GoogleSearch
                                          ▼                                     ▼
                                ┌──────────────────────────────────────────────────┐
                                │                  Gemini API (Google)             │
                                │   Live (3.1 Flash) · 2.5 Pro · 2.5 Flash         │
                                └──────────────────────────────────────────────────┘
```

---

## 3. Module-by-module feasibility

### 3.1 Identity (NEW — must build)

**Recommendation: Sign in with Apple + Google Sign-In, JWT-backed, no passwords.**

- **Apple Guideline 4.8 forces this**: if you offer Google Sign-In, you *must* offer an "equivalent option" — Sign in with Apple meets it. Don't ship without both.
- **Server**: add `/api/auth/apple` and `/api/auth/google` endpoints that verify the platform-issued ID token, mint a SousLens JWT, and upsert a user row. ~300 LOC of FastAPI.
- **iOS**: use `AuthenticationServices.ASAuthorizationAppleIDProvider` (zero SDK weight) + Google Sign-In SDK (`GoogleSignIn` SPM). Persist the SousLens JWT in Keychain.
- **DB pivot**: every existing table (`procedures`, `steps`, new `pantry`, `taste_events`) gains `user_id` FK. SQLite is fine for testflight; budget a Postgres migration before public launch.
- **Effort**: ~1 week for SSO + token plumbing; ~3 days to retrofit `user_id` scoping into every router.
- **Privacy bonus**: Apple's relay-email feature naturally aligns with "privacy-first."

### 3.2 Privacy-first data architecture (NEW — non-negotiable)

The single highest-risk deviation from Retrace. Concrete actions:

| Concern | Concrete behavior |
|---|---|
| Kitchen footage stays on the phone by default | Inventory scans run **on-device** via Apple Vision + Apple Intelligence Foundation Models (iOS 18.2+, 3B on-device LLM). Don't upload frames |
| Cooking recordings are user-controlled | Local-first via SwiftData. Cloud upload is opt-in, per-recipe, with a clear toggle |
| Personal recipes default private | Per-user scoped DB. Sharing requires an explicit "Share to community" action |
| Gemini Live disclosure | Privacy policy must list Google as a third-party processor. The voice + frame stream is in-scope |
| Data export + deletion endpoints | `GET /api/me/export` (zip of recipes + scans + history) and `DELETE /api/me` (cascade) — required for App Store + GDPR |
| App Privacy Report compatibility | Audit every server call's purpose; populate the Privacy nutrition label honestly. *Don't* claim "Data Not Collected" if you upload anything |

**Apple Foundation Models (`FoundationModels` framework, iOS 18.2+)** is genuinely useful here — on-device 3B LLM can do ingredient classification + recipe step detection without a network call. Worth a deep dive once we're scoping inventory scan.

### 3.3 Recipe capture (REUSE — Retrace's expert flow, ~90% as-is)

- **Reuse**: `/api/expert/upload`, `gemini_processor.py`, `clip_extractor.py`, the `Procedure` / `ProcedureStep` model, the iOS `ExpertTabView` + `RecordTabView`.
- **Adapt**:
  - Rename `procedure → recipe`, `step → step` (works as-is).
  - Update the extraction prompt in `gemini_processor.py` to extract recipe-specific fields: ingredients per step (with quantity + unit), heat level, time, equipment, doneness signals (the cooking analog of `completion_criteria`).
  - Reuse the *exact* clip-slicing pipeline. The "ghost hands" UX is just the same per-step MP4 played as PiP.
- **Effort**: ~1 week, mostly prompt engineering + model schema diffs.

### 3.4 Cookbook PDF ingest (REUSE — Retrace's manual ingest, verbatim)

- `/api/expert/manuals/upload` already turns a PDF into a structured procedure with rendered page images per step. This is the **exact** primitive needed for "Mom's signature dish, written down on a printed card" or "page from a cookbook."
- **Effort**: ~2 days of prompt tuning for cooking-specific extraction. Re-use the iOS upload UI.

### 3.5 YouTube Shorts / online video ingest (NEW — answer to your direct question)

**You asked: build a custom backend or integrate an existing API?**

The real fork is *do you download the video, or just the transcript*. Three viable options, ordered by recommendation:

| Option | What | Risk | Best for |
|---|---|---|---|
| **A. Transcript-only ingest** *(recommended)* | User pastes URL. Server fetches transcript via `youtube-transcript-api` + oEmbed metadata. Gemini 2.5 Pro structured-output emits a recipe schema directly from the transcript + title + thumbnails. **No video download, no ToS violation.** | Low. No video bytes touched. Falls back to "please screen-record and upload" if the Short has no transcript (~20% of Shorts). | App Store-distributable, privacy-clean, fast |
| **B. User screen-records, then uploads** | User screen-records the Short on their phone, drops it into the existing expert upload flow. Reuses the entire video pipeline. | None. The user is the one who copied the bytes; you're processing user-supplied media. | Fallback for option A. Already works today. |
| **C. Server-side `yt-dlp`** | Download the Short, run it through the existing video pipeline. | High. YouTube ToS forbids it; Apple Guideline 5.2 has rejected apps for this; Google has issued takedowns to apps that did. | Don't ship this on the App Store. |

**Architecture for Option A**: extend Retrace's `web_search_for_fix` pattern (Gemini Pro + structured-output) in `services/troubleshoot/web_research.py` — that's the exact same shape: free-form input → structured procedure JSON. Rename to `services/recipe_ingest/from_url.py` and swap the schema. ~3 days of work.

> Don't try to extract step-level *visual* clips from a YouTube Short you didn't download. The thumbnails-only path is honest about its limitation: "this recipe was synthesized from the transcript; visuals come from your own camera while you cook." That framing is a feature, not a bug.

### 3.6 Pre-cooking inventory scan (NEW — high effort)

Three viable architectures:

| Path | Stack | Privacy | Accuracy | Effort |
|---|---|---|---|---|
| **A. On-device only** | Apple Vision (object detection) + Apple Foundation Models (3B LLM, iOS 18.2+) for label refinement | Frames never leave the phone — *this is the privacy-first claim* | Decent for common produce, weak for niche items (e.g. Chinese 5-spice) | 3–4 weeks |
| **B. Hybrid (recommended)** | On-device Vision proposes candidates; user confirms or "send to cloud for help" with explicit consent → Gemini Vision refines | Default private, escalation explicit | Best | 4–5 weeks |
| **C. Cloud-only** | Stream frames straight to Gemini Vision | Worst | Best | 1 week |

Recommend **B**. The "default private, optional cloud" is the same shape as iOS Photos' search — it's a familiar pattern users trust.

State storage: a `pantry` SwiftData table on-device (canonical) with optional bidirectional sync to the server (so taste-profile inference can run server-side without exposing items by name; sync the embedding, not the literal "you have anchovies").

### 3.7 Smart substitutions (NEW — moderate effort, big reuse)

- **Pattern**: `web_search_for_fix` in Troubleshoot already returns "given a free-form input, search the library or synthesize a fresh procedure from web grounding." For SousLens, the input is `(target_recipe, missing_ingredient, available_pantry)` and the output is `(substitute, ratio, caveats, citations)`.
- Reuse `services/troubleshoot/web_research.py` directly. Swap the prompt + schema. Add a tool: `suggest_substitution(missing, pantry)` to the coaching tool dispatcher so it can fire mid-session ("you don't have cilantro? we can sub parsley + a squeeze of lime, but parsley wilts faster — add it last").
- **Effort**: ~1 week.

### 3.8 Taste profile + adaptive discovery (NEW — moderate effort)

- **Local-first** via SwiftData. Every interaction (saved, completed, rated, abandoned, ingredient-disliked, cuisine-tagged) is a row.
- **Embedding**: Apple's NLContextualEmbedding (iOS 17+) is on-device and free. Embed each recipe's title+description+cuisine; embed the user's taste history; cosine-similarity rank.
- **Discovery dashboard**: cross-reference `pantry × taste_embedding` server-side (only the embeddings, not the raw items). Server returns ranked recipe IDs; phone resolves details.
- **Effort**: ~2 weeks for v1.

### 3.9 Hands-free interaction (REUSE + extend)

- Voice commands during coaching are already free — Gemini Live handles barge-in.
- The `HandTracking/` substrate (`HandLandmarkerService` + `HandGestureService`) was built for the Ray-Ban HUD; it works as-is for iPhone-mounted-on-counter usage. Pinch + hover already implemented.
- **Glasses**: see §4 below — has a major distribution caveat.

### 3.10 Recipe-specific UX (NEW — design + implementation)

- The Retrace `design.md` is *industrial* (technicians, error codes, hazard yellow). SousLens needs a different aesthetic — warmer, food-photography-friendly, while keeping the same "tool, not toy" rigor.
- Reuse the *system* (token-driven Asset Catalog, Golos Text scale, monochrome-with-accent rule, no-shadows-on-OLED). Re-skin the *tokens*.
- Reuse component shells (`CardView`, `CustomButton`, `MetadataPill`, `StepProgressBar`). Add: `IngredientChip`, `PantryGrid`, `SubstitutionPill`, `RecipeHeroCard`.
- **Effort**: 2–3 weeks for design pass + token migration; component re-skin happens incrementally.

---

## 4. The hardware-distribution question (read this carefully)

**Meta DAT SDK status**: Retrace ships with the Meta Wearables DAT SDK 0.6 today. Until early 2026 this required an approved Meta developer account. Verify before public release: as of now `dat-ios-test` is a public mirror but the SDK's *consumer App Store distribution* status changes faster than this doc can. **Action: confirm with Meta DAT support that `com.xrcc.retrace.ios.v1` (or a SousLens-equivalent bundle) can ship to the public App Store with the SDK embedded.** If no, you have two options:

- **Strip glasses entirely from the App Store build** — ship iPhone-only on the App Store, keep a TestFlight track that includes the DAT SDK for glasses-equipped beta testers. This is the cleanest path and is what I'd recommend for v1.
- **Wait for DAT SDK public-distribution clearance** — risky timing-wise.

**Mentra glasses + others**: your other repos suggest you've got Mentra and Ray-Ban Display work elsewhere. SousLens v1 should be **iPhone-only on the App Store**, glasses support follows in v2 once the distribution path is settled. The capture transport abstraction Retrace built makes this a one-line addition later.

---

## 5. Effort estimate (rough, for SousLens v1 = iPhone-only, App Store-ready)

| Workstream | Weeks | Notes |
|---|---|---|
| Fork + rename (`com.souslens.ios`, asset rebrand, README/CLAUDE.md) | 1 | Mostly mechanical |
| Identity (Apple + Google SSO, JWT, server retrofit, per-user scoping) | 2 | Includes DB schema changes |
| Privacy posture (export/delete endpoints, app privacy label, on-device default) | 1.5 | Mostly disciplined plumbing |
| Recipe capture flow (reuse expert + reword prompts) | 1 | Prompt + schema work |
| YouTube transcript ingest (Option A) | 0.5 | Direct port of `web_research.py` |
| Cookbook PDF ingest (reuse manual flow) | 0.5 | Tune prompt |
| Inventory scan (hybrid on-device + opt-in cloud) | 4 | Highest-novelty module |
| Substitution engine (reuse web_search_for_fix) | 1 | |
| Taste profile + discovery dashboard | 2 | |
| Recipe UX design + token re-skin | 2.5 | Parallelizable with backend work |
| Coaching flow re-tune (cooking timing, doneness signals, multi-step parallel) | 1.5 | Re-prompt + new tools |
| App Store prep (privacy nutrition, screenshots, App Review notes) | 1 | |
| **Total (sequential floor)** | **~18 weeks** | |
| **Total (with parallelism, 2 people)** | **~10–12 weeks** | |

Critical path: identity → privacy plumbing → inventory scan. Everything else either reuses Retrace heavily or runs in parallel.

---

## 6. Risks (ordered by severity)

1. **Meta DAT SDK App Store eligibility** — see §4. Mitigation: ship iPhone-only on the App Store.
2. **App Store Guideline 4.8 (Sign in with Apple)** — must ship Apple SSO if you ship Google SSO. Easy mitigation, just don't forget.
3. **Privacy nutrition labels misrepresented** — Apple actively rejects apps that claim "Data Not Collected" while talking to a third-party LLM. Mitigation: write the privacy policy *first*, not last.
4. **Gemini Live cost at scale** — at ~33 tok/s of video + audio, a 30-min cooking session is ~60k tokens of input alone. Live preview pricing is currently low but not free; budget for $0.30–$1 per cooking session before optimization. Mitigation: aggressive PiP-only-on-demand; consider on-device Apple Foundation Models for the simple "is the onion translucent yet?" path with Gemini as escalation.
5. **YouTube ingest going stale** — `youtube-transcript-api` breaks every few months when Google ships changes. Mitigation: keep a fallback to "screen-record + upload" front and center.
6. **Vision model accuracy on long-tail produce / pantry items** — fundamental limit. Mitigation: always expose a manual-edit path on the inventory list.
7. **Server scale** — SQLite + Lightsail $12/mo box is fine for hundreds of users, will fold at thousands. Mitigation: budget Postgres + horizontal scale before any growth marketing.
8. **In-home recording → privacy story is hard to defend if it leaks** — single biggest reputation risk. Mitigation: default to *no cloud upload at all* for cooking recordings; make sharing a deliberate, named user action.

---

## 7. Recommended next 3 steps

1. **Decide v1 scope**: (a) iPhone-only on App Store + glasses on TestFlight, *or* (b) hold for DAT SDK public clearance and ship glasses + iPhone together. I'd pick (a) — get to App Store in weeks not quarters.
2. **Stand up identity + privacy scaffolding before any feature work**. Fork Retrace, add `user_id` to every table, add Apple+Google SSO, add `/api/me/export` + `/api/me`. This is the slowest "boring" part, and the rest of the team can build cooking features on top without it being a blocker.
3. **Prototype inventory scan first** — it's the highest-novelty, highest-risk module. If it works at acceptable accuracy with the on-device Apple Foundation Models path, you have a defensible privacy story; if it doesn't, you need to design the cloud-fallback UX honestly. Don't defer this; it shapes everything else.

---

## 8. Direct answer to your question

> "Are you planning to build out a custom backend for processing those external YouTube Shorts into step-by-step formats, or are you looking to integrate an existing video-parsing API?"

Neither, in the sense you asked. **Recommendation: parse the *transcript*, not the *video*.** Retrace's `services/troubleshoot/web_research.py` already does the hardest part — Gemini Pro + GoogleSearch grounding emitting a structured-output procedure JSON with cited URLs. Swap the prompt + schema and you have YouTube-Shorts-to-recipe in ~3 days. Use `youtube-transcript-api` for the transcript (free, no API key, breaks occasionally — keep a fallback). Don't run `yt-dlp` server-side; it's a Google ToS violation and an App Store reviewer flag. For Shorts with no transcript, route the user back to the existing screen-record-and-upload path — same outcome, legally clean.
