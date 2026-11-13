# 013 — Rebrand to Umma (persimmon) + calm portrait cooking

**Status:** shipped (repo + folder rename pending) · **Owner:** PM · **PR:** #14, #15, #16 · **Updated:** 2026-11-12

## Problem
"SousLens" reads as an AI-generated name and says nothing about the idea the product came from:
a mum handing her recipes down. The current Mise look (cream paper, herb green, serif) is close
to the generic "AI warm cream" style. Separately, the portrait cooking screen is cluttered.
Step 1 of the seeded recipe shows three stacked notice banners, an "Adapted" chip and a progress
bar before the step text. The step text runs under the controls, and there are seven buttons.
Landscape already looks clean. A cooking screen should feel calm.

## Who it's for
- Everyone who sees the product: testers on TestFlight, visitors to the website, portfolio viewers.
- Home cooks mid-recipe with busy hands (Part B).

## What success looks like
- Nowhere a user can see, in the app, the website or the portfolio, says "SousLens". The product
  is **Umma (엄마)**, in the persimmon direction from `docs/brand/umma-directions.html` (option C).
- A tester recognises the brand from the home-screen icon alone.
- In portrait cooking, the step text is the first thing you read. Nothing sits on top of it, and
  the screen looks like the landscape one.

## Acceptance criteria

### Part A: name and brand (PR 1)
- [ ] **Logo.** A final persimmon mark and an "umma" wordmark as SVG masters in
      `docs/brand/`, plus a lockup with 엄마. The mark reads at 29 pt.
- [ ] **App icon.** iOS light, dark and tinted variants in the asset catalog, built from the
      mark. It replaces the leaf-lens icon.
- [ ] **Brand tokens.** The DesignSystem moves to Persimmon (#F2782A), Leaf (#2F6B3A), Flesh
      (#FFF1E6) and Seed (#2A1C14), with designed dark-mode values. Every text/background pair
      still passes the AA (4.5:1) token unit test. Persimmon is not used for body text on light
      backgrounds, because it fails 4.5:1.
- [ ] **Typography.** See Q4.
- [ ] **Copy.** The app name, launch screen, empty states, onboarding, permission prompts
      (Info.plist usage strings), Settings and the share sheet say Umma. Locked safety wording
      (DECISIONS #15) does not change.
- [ ] **Code and config rename.**
  - Xcode targets, schemes and folders: `SousLens*` → `Umma*`, via `ios/project.yml`.
  - Bundle IDs, per Q2.
  - Backend: logger names (`souslens.*`), DB names (`souslens`, `souslens_test`), docker
    compose, the Makefile, CI workflows, prompts and READMEs.
  - The fixture `expected_outputs/recipe_detail.json` and its iOS copy, regenerated together.
- [ ] **Docs.** PRD, `CLAUDE.md`, READMEs and every brief say Umma. `DECISIONS.md` stays
      append-only: past entries keep their wording, and a header line and entry #23 record the
      rename.
- [ ] **Outside this repo, under `~/Documents/Projects`.**
  - `CLAUDE.md`, `PROJECTS-PORTFOLIO.md`, `RESUME-*.md` and `.claude/scripts/install-on-phone.sh`.
  - PersonalWebsite: the work entry `souslens.md` → `umma.md`, and the lab pages. This goes
    through a worktree branch in that repo, since another session is active there.
- [ ] **Repo and folder.** See Q3.
- [ ] `make check` passes. iOS CI runs green on the branch.

### Part B: website (PR 2)
- [ ] `site/` is rebuilt in the persimmon brand: the Bagel Fat One wordmark, Nunito text and
      the persimmon palette, in light and dark, down to 320 px, with Lighthouse a11y ≥ 95.
- [ ] It keeps everything brief 011 required: the TestFlight CTA from one config value, the
      privacy and support pages, the "in development" glasses note, and the reserved AASA path.
- [ ] The privacy copy describes the Free/Paid voice tiers (DECISIONS #22) instead of "voice
      stays on your phone".
- [ ] The origin story ("it started with my mum's recipes") and the tagline appear above the
      fold.
- [ ] Screenshots are real captures from the rebranded build.
- [ ] It's ready for a Vercel preview. Production stays on the PM's go.

### Part C: calm portrait cooking (PR 3)
- [ ] The step text is the first content under a slim header (recipe name, a progress bar, the
      step count). No banner sits above the step.
- [ ] Notices follow Q1.
- [ ] The step text never runs under the controls. The content area ends above the control bar,
      and long steps scroll.
- [ ] Controls: Back, Next, and a mic/pause button. Repeat, Slower, Ask and Look move into one
      "tools" button or the voice layer, per Q1.
- [ ] Portrait and landscape share one layout language, so they look like the same screen.
- [ ] It still lays out at AX5 Dynamic Type. VoiceOver reads the step, then any safety notice,
      then the controls.

## Out of scope
- Buying a custom domain (it spends money; the site stays on `*.vercel.app`).
- Voice mode itself (brief 012).
- Changing the glasses DAT registration name beyond the bundle ID.
- Rewriting git history.

## Open product questions
1. **Portrait cooking notices: how calm?**
   Options: A (safety and allergy notices stay visible as one compact line under the step text;
   the creator tip and "not an exact match" fold into a small "2 notes" chip; the adapted/original
   toggle moves into the ⋯ menu), B (everything except allergy folds into the chip), C (all
   notices stay inline, only restyled). **Recommendation:** A. It's calm and still never hides a
   safety rule.
   → *Answer:* A.
2. **Bundle ID?** Options: A (`com.umma.ios` now), B (keep `com.souslens.ios`).
   **Recommendation:** A. Nothing is in App Store Connect yet, so changing it now is free. After
   the first TestFlight upload it can't change.
   → *Answer:* A, `com.umma.ios`.
3. **GitHub repo and project folder?** Options: A (rename the repo `hshwang34/SousLens` →
   `hshwang34/Umma` and the folder `Projects/SousLens` → `Projects/Umma`, as the last step once
   no SousLens session is running), B (rename the repo only), C (leave both).
   **Recommendation:** A. GitHub redirects the old URL, and the folder move happens last so
   running sessions don't break.
   → *Answer:* A, rename both as the last step.
4. **App typography?** Options: A (Bagel Fat One for the logo and large screen titles only;
   SF Pro and SF Rounded everywhere else, which is native), B (Nunito everywhere, with Bagel for
   titles), C (keep New York serif titles). **Recommendation:** A. It's native-feeling and keeps
   the brand moment where it counts.
   → *Answer:* A.

## Sequencing
PR #13 (glasses) is parked (DECISIONS #24) and no longer blocks. Then Part A → Part B → Part C, one writer
at a time, one worktree branch each. Part C can start in parallel with B, because they touch
different files.

## Engineering decisions (filled in by the lead while building)
- Tagline (copy, changeable): "Your mum's recipes. Your fridge. Dinner." Secondary line:
  "Cook it the way she makes it."

## Risks / what could go wrong for users
- Existing simulator/TestFlight installs see a new bundle ID as a different app. The Keychain
  token and caches don't carry over, so testers sign in again (acceptable before launch).
- The rename touches about 500 references. A missed one in a test fixture breaks CI rather than
  users, and the gate catches it.
- Persimmon on cream fails contrast for text. It's limited to fills, icons and large display
  text.
