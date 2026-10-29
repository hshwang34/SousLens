# Product decision log

Append-only. Newest at the bottom. When a decision is reversed, add a new entry and mark the old
one `SUPERSEDED by #n` — don't delete it. Agents read this before raising a product question.

Format: `#n · date · decision` — then *why*, and where it lives in code/docs.

---

#1 · 2026-10-20 · **Repo bootstrapped under the personal identity.** `git init` on `main`, commits as
`jacogoby@gmail.com`, private GitHub repo `hshwang34/SousLens`, Apple Team `V56DG94ZL5`, bundle id
`com.souslens.ios`. *Why:* project lives under `~/Documents/Projects/` → personal accounts only.
*Lives in:* `.git/config`, `CLAUDE.md`.

#2 · 2026-10-20 · **The October PRD (v1.0, 2026-10-15) is the single source of truth; the May
PRD and Retrace scoping audit are archived.** Product name is **SousLens** (the handed-over file said
"SuisLens"; renamed throughout). Old-PRD features — YouTube transcript ingest, AI-generated recipes
with citations, Apple Reminders shopping-list write-back, Aisle Assist, 4-week App Store target — are
**not in P0**. They may return as P1 briefs if the PM asks. *Why:* the two documents conflict on the
core loop; the PM chose the creator-published-recipe model. *Lives in:* `PRD.md`, `docs/archive/`.

#3 · 2026-10-20 · **Build Slices 0–3 now, one brief + one PR per slice, then stop.** Slice 0 is split
into two independent features (backend foundation, iOS foundation) so they can be built in parallel
worktrees. All four slices run on `MockAIProvider`: zero AI spend, no video processing, no glasses
hardware. Slice 4 (real Gemini voice/vision), 5 (video extraction), 6 (Meta glasses) and 7
(hardening/pilot) each need a product/spend call from the PM before starting. *Why:* PRD §16.2 says
slice-by-slice with gates; the PM pre-approved the first four. *Lives in:* `docs/product/briefs/001–005`.

#4 · 2026-10-20 · **PRD §19 default answers are adopted as product decisions** so agents never re-ask
them: AI cooking tutor anchored in creator recipes (social graph later); no AI-generated recipes as a
primary flow; no external TikTok/Instagram video in P0; pantry images not stored by default; no pantry
auto-decrement; AI never auto-advances steps; first content vertical is 5–10 simple recipes incl.
Korean home cooking (not exclusively); display-less glasses are the baseline; glasses failure → full
phone-only session; Gemini-family provider behind interfaces; P0 social = feed/save/share only; no
continuous video to the model, single deliberate frames only. *Lives in:* `PRD.md §19`.

#5 · 2026-10-20 · **Dev-pilot auth is backend-native email sign-in (no password; one-time code shown
in the server log in dev), issuing a SousLens JWT.** Sign in with Apple is deferred to Slice 7
(hardening) behind the same `AuthProvider` interface. *Why:* AUTH-01 only needs testers to sign
in/out with isolated private records; no third-party auth dependency should block Slices 0–3.
Engineering call by the lead, surfaced here because it is what testers see. *Lives in:* brief 001.

#6 · 2026-10-20 · **Units: US-customary display with metric toggle per user preference** (PRD §0).
Seed recipes are the five in PRD Appendix B, authored as original fixtures. *Lives in:*
`fixtures/seeded_recipes/`.

#7 · 2026-10-20 · **Any signed-in tester may publish recipes in the pilot** (no creator allowlist).
Brief 003's default, adopted because the pilot is 5–10 known people; revisit before any public
build. *Lives in:* brief 003, backend publish endpoint (no role check).

#8 · 2026-10-20 · **Slice 1 is built as two PRs stacked on the Slice 0 branches** (backend on PR #1's
branch, iOS on PR #2's) so work continues while the PM is away; GitHub retargets them to `main`
when the parents merge. PRs #1/#2 only received security-review fixes after their gates. *Why:*
the PM pre-approved Slices 0–3 and is not watching in real time.

#9 · 2026-10-20 · **Merges of PRs #1/#2 may be performed by the orchestrator session (`projects-ee`),
which states it holds merge authority delegated by the PM.** Recorded as stated by that session,
not confirmed by the PM in this conversation; the PM should strike this entry if it is wrong.
Standing rule from the same session: a confirmed security finding in an open, unmerged PR is
fixed in that PR immediately with a one-line note in the PR body; non-security changes to a
gated PR still wait. *Lives in:* PR bodies #1/#2.

#10 · 2026-10-23 · **#9 is confirmed.** The PM's global instructions now state that the orchestrator
session carries the PM's authority for brief approval, prioritisation, stacking, and merging
fully green PRs, but not for deploys, deletions, account changes or spend. Merges are CI-gated:
the eng lead merges when every check is green and the gate passed.

#11 · 2026-10-23 · **Slice 2 product defaults (PRD-derived, logged rather than asked).** Photo scans
in mock mode are labelled "Demo mode — not a real detection" (PRD Appendix C). Duplicate pantry
items are always resolved by the user (merge or keep both), never silently (PAN-04). A pantry item
last confirmed more than 14 days ago counts as "uncertain" for recipe fit. Pantry photos are
processed in memory and never stored; candidate lists expire after 24 h. Confidence bins are
PRD §8.3's (>0.85 high, 0.6–0.85 medium, <0.6 unknown) and are labelled as estimates. On iOS,
"Type instead" and "Choose photo" sit beside the mic and camera so the flow works without a
microphone or camera (and in the simulator). *Lives in:* `docs/product/briefs/004-api-contract.md`.

#12 · 2026-10-23 · **Pantry provenance follows how the user entered it:** typed text is "Manual",
dictated text is "Voice" (also when edited after dictation), photos are "Photo" (PAN-05). Items from
a mock (demo) photo scan start unticked so demo data never lands in a real pantry by default.
*Lives in:* iOS ScanReviewViewModel; backend stores the client-sent source.

#13 · 2026-10-23 · **A photo-estimated quantity never makes a recipe line "available".** It caps
the line at "uncertain" with "the amount is an estimate from a photo — check it", and estimates
are never added up. Typing your own amount removes the estimate. *Why:* PRD §8.3 ("mark estimates
as such; ask the user to confirm") and FIT-03 (never claim "you can make it" on uncertain data).

#14 · 2026-10-23 · **Slice 3 product defaults (PRD-derived, logged rather than asked).**
- A suggested timer is offered as "Start a 10-min simmer timer?" with Start / Skip; nothing starts
  without a tap (brief 005 Q1, PRD §6.1).
- Profile gains "Allergies & foods to avoid" (SUB-02 is P0). Allergies are hard blocks on
  substitutions; "avoid" is a soft preference. The app never says a substitute is "safe for you".
- Swaps are labelled "Common swap" (vetted seed table) or "AI suggested adaptation"; adapted step
  text always shows the original one tap away, and any swap can be reverted mid-cook.
- Finishing a cook offers a private note and "Save my changes" (a private variation reused next
  time via "Use my changes from last time"). No public forks until P1.
- The coach answers typed questions only in Slice 3, from the recipe as published; food-safety
  questions always point to a thermometer / verified guidance.
*Lives in:* `docs/product/briefs/005-api-contract.md`.

#15 · 2026-10-23 · **The coach never answers "is it done / safe to eat?" in its own words.** Any
doneness or safety question gets a fixed answer: what the recipe says to look for, how to check
with a thermometer, and "I can't tell from a description or photo whether food is cooked". For
high-risk foods (poultry, pork, ground meat, fish, eggs) this notice is attached to any question
that isn't plain navigation. "Free-from" labels (lactose-free, gluten-free, nut-free) never clear an
allergy match; the app asks you to check the label instead. Allergy entries the app can't
recognise are shown back to you as not-checked. *Why:* PRD §13.1 hard requirements; reviewer
found model-prose filtering bypassable and allergy matching too narrow.

#16 · 2026-10-23 · **Slice 3 shipped with these eng-lead calls (PM may revisit).**
- **Cautious over helpful on preservation.** Any recipe mentioning pickling, kimchi, curing,
  brining or fermenting treats its salt, acid, sugar and ferment ingredients as not swappable. So
  salt and soy swaps in Kimchi Fried Rice say "not recommended" for now. To refine: tell "makes
  kimchi" apart from "uses kimchi".
- **Safe temperatures come from our own USDA table,** never the model, and open with "I can't
  confirm…" like every other safety answer.
- **An unconfirmed Done is locked.** If finishing a cook didn't reach the server, its
  outcome/note can't be edited until it's resent or discarded, so a late tap never overwrites a
  newer answer.
- **A third backend fix round** (past the usual two) was run because the review found allergy
  phrasings like "I'm allergic to peanuts" weren't matched. Safety blockers don't ship.
*Lives in:* `docs/product/briefs/005-api-contract.md` (fix-round clarifications).

#17 · 2026-10-23 · **Brand = "Mise" (warm editorial); redesign the core loop first.**
- **Brand.** Cream paper #FBF6EE, herb green #2F6B3A, tomato #B3401E. New York serif for
  titles, SF Rounded for numbers. A calm, plain voice.
- **Liquid Glass.** It goes on the controls layer only. Content and safety notices stay solid.
- **iOS.** Keep iOS 17.2+, with a frosted fallback below iOS 26.
- **First PR.** Explore, Recipe and Cooking. Pantry, Creator and Profile come in PR 2.
- **App icon.** Eng draws the app icon in code for the pilot.

*Why:* PM choice from the brand board (`docs/product/design/brand-board.html`), on the
designer's recommendation: it fits trust and safety messaging and builds on the existing serif.
*Lives in:* `docs/product/briefs/006-brand-mise-core-loop.md`.

#18 · 2026-10-28 · **Go to finish P0 and release a public TestFlight beta with a product site.**
- **Gemini spend: go, $25/month hard cap.** Uses the PM's personal Gemini key. The backend enforces
  per-user daily limits and a monthly kill-switch. When the cap is hit, the app falls back to the
  labelled mock/AI-off path; it never fails silently. Unlocks Slices 4 and 5.
- **Glasses: full build (Slice 6).** The PM has compatible Meta glasses. Use the latest publicly
  released Meta Wearables Device Access Toolkit. The release pipeline (registration, Meta app
  config, TestFlight distribution with DAT) must be fully laid out.
- **Hosting: Fly.io + Fly Postgres + Tigris object storage,** on the personal Fly account
  (jacogoby@gmail.com).
- **Release: Sign in with Apple** replaces dev-login in production. **Product site on Vercel**
  (personal `hshwang34`) with the public TestFlight link.
- Each actual production deploy, App Store Connect upload and the TestFlight external-review
  submission still gets a one-line confirmation from the PM at that moment.
*Lives in:* briefs 006–010.

#19 · 2026-10-28 · **Release shape after research.**
- **Hosting: Fly.io (API + worker + Tigris) with Neon Postgres free tier.** This replaces Fly
  Managed Postgres ($38/mo). The target is about $5–10/mo plus Gemini.
- **Glasses ship to the PM only, via Meta Developer Mode.** Meta does not yet allow App
  Store distribution of DAT apps, and the SDK's ExternalAccessory use risks Apple review
  rejection. So the **public TestFlight build does not link DAT at all**. A separate glasses
  build (`MetaAppID=0`, custom URL scheme) installs on the PM's phone. The path to Meta release
  channels and App Store GA is documented in `docs/release/` for when Meta opens it.
- **Voice: Apple on-device speech** (SFSpeechRecognizer on-device + AVSpeechSynthesizer). Audio
  never leaves the phone, and the transcript is shown before it's sent. Gemini audio is not used.
- **Gemini runs on the paid tier only.** Free-tier prompts may be used for training, which
  conflicts with the photo privacy promise. It runs in a dedicated personal Cloud project. Models:
  `gemini-3.8-flash` for coach, inspect and video, and `gemini-3.5-flash-lite` for pantry photos.
  Ids get re-verified at build time.
- **Budget guard:** soft-degrade at $15 (video extraction off), hard stop at $22 of the $25 cap,
  then fall back to labelled mock. Per-user caps: $0.25/day and 5 video extractions.
*Lives in:* briefs 007–011.

#20 · 2026-10-28 · **Briefs 007–011 approved.**
- **Creator source video:** kept until the creator deletes it (not auto-deleted after publish).
  Delete is always available from the creator's recipe screen.
- **Public TestFlight link:** capped at 100 testers.
- **Support / privacy contact:** jacogoby@gmail.com.
- **Site domain:** the free `*.vercel.app` domain for the beta.
*Lives in:* briefs 008, 010, 011.
