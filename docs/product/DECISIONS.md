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
