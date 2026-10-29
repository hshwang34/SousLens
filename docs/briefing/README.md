# Briefing cache

Reusable screenshots and facts for executive briefings, so a new briefing doesn't need a
new capture session. Reuse what's still current; recapture only screens whose feature changed.

## Files
- `souslens-briefing-features-2026-10-29.html`: the features briefing, self-contained (images
  embedded). Its text holds the feature inventory, status per feature, and "Not covered, and why".
- `assets/*.jpg`: the 53 source images, already resized (≤1600 px).

## Capture provenance (2026-10-29)
| Images | Source | Notes |
|---|---|---|
| `01`–`40` (no prefix) | `origin/main` @ b69c5cb, iOS 17.5 sim (iPhone 15), backend `AI_PROVIDER=mock`, seeded demo data | Pre-redesign look. `r` suffix = a retake. Six frames are cropped above the keyboard. |
| `mise-*` | Review branch `feature-brand-mise` @ 328f0b2, iOS 17.5 | Mise redesign before fix round 1 (shows the frosted fallback, not iOS 26 glass). |
| `mise-r1/*` | `feature-brand-mise` @ acab7f7 (fix round 1), iOS 17.5 light + iOS 26.2 dark (real glass), plus AX5/XXXL text sizes | The current redesign; use these instead of `mise-*` once 006 merges. |
| `site-desktop`, `site-mobile` | `site/` served locally, before deploy | Screenshot slots still show placeholders. |

## Feature → image map
- **Sign-in:** 01, 02
- **Explore, search, no match:** 03, 04, 04b
- **Recipe page:** 05, 05b, 05c. **Save:** 06, 07, 08r. **Share:** 06b
- **Pantry:**
  - empty: 09
  - say it: 10a
  - review: 11
  - list: 12
  - add by hand: 13
  - scan sheet: 14
- **Allergies / preferences:** 15
- **Pantry fit:** 16, 16b
- **Swaps:** 17 (allergy-blocked), 18, 19
- **Cooking:**
  - step: 20
  - coach: 21r
  - adapted step: 22
  - timer: 23
  - paused: 24
  - menu: 25
  - finish: 27, 27r
  - resume pill/banner: 39, 40
- **Creator:**
  - profile: 29
  - draft: 30, 33
  - ingredient/step editors: 31, 32
  - preview: 34
  - publish: 35, 36
  - my recipes: 37, 38

## Stale when
- **The redesign (brief 006) merges:**
  - All the un-prefixed Explore, Recipe and Cooking shots (03–06, 16–27, 39–40) show the old
    look. Recapture them on iOS 26.2 and 17.5.
  - `mise-*` are replaced by the post-fix captures.
- **The iOS side of real AI / Look / voice / video upload ships:** the feature becomes capturable.
  Until then it's a concept tile or text.
- **The site is deployed:** recapture from the live URL. Add the app screenshots to
  `site/assets/screens/` first.

## Never captured (needs a real device or a new test)
Error and offline screens, read-aloud, the real mic and camera, the pantry photo result (Apple's
photo picker), Edit → v2, the unfinished-cooks limit and Stop dialogs, units, opening shared
links, and "Use my changes from last time" on a second cook.

## How the capture was run (to redo it cheaply)
- **Isolation:** a detached worktree of `origin/main`, its own simulator ("SousLens Briefing",
  iPhone 15, iOS 17.5), its own backend on :8010 and its own database `souslens_brief`. The
  database was seeded with `make seed`, and the app was pointed at the backend through the
  smoke-test launch args.
- **Navigation:** a throwaway XCUITest patterned on `ios/SousLensSmokeTests`, calling
  `XCUIScreen.main.screenshot()` at each state. It was deleted afterwards. Next time, keep it as
  a `SousLensBriefing` UI test target so recapture is one command.
