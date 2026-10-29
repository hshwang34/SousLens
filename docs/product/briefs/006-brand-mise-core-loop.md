# 006 — Mise brand + Liquid Glass, core loop

**Status:** building · **Owner:** PM · **PR:** — · **Updated:** 2026-10-28

## Problem
The app works, but it looks like a stock SwiftUI prototype. There are bordered rectangle cards,
a generic tint, no hierarchy on Explore and no motion. Cooking mode carries about 250pt of
opaque chrome under the step. Nothing says "SousLens", and nothing makes the moments that matter
(you can make this, step done, timer finished) feel good. The pilot needs a product people want
to open.

## Who it's for
- Home cooks, at three moments: browsing (Explore), deciding (Recipe detail and pantry fit), and
  cooking hands-busy (Cooking mode).
- Creators come in the second PR.

## What success looks like
- A pilot tester recognises the app as one brand: Mise (warm paper, herb green, New York serif,
  SF Rounded numerals).
- On iOS 26 the controls layer is Liquid Glass. On iOS 17–25 it is a frosted fallback.
- Cooking mode reads from arm's length. The step owns the screen and controls float.
- The signature moments animate, and each has a Reduce Motion fallback.

## Acceptance criteria
- [ ] **Brand tokens.** The DesignSystem is rebuilt on Mise colours, with light and dark
      (palette in `docs/product/design/brand-board.html`). The asset colour sets are updated.
      Every text/background pair is AA (4.5:1), checked by a unit test over the token table.
- [ ] **Typography.** New York for display and titles, SF Pro for body, SF Rounded for
      quantities, timers and step numbers. All of it uses Dynamic Type styles, with no fixed sizes.
- [ ] **Adaptive glass.** One `adaptiveGlass` helper:
  - iOS 26: `glassEffect` / `GlassEffectContainer`.
  - iOS 17–25: material.
  - Reduce Transparency on: a solid surface.
  - Glass is used only on the controls layer. Recipe text, ingredients, step text, allergy and
    safety notices, errors and dialogs are always solid.
- [ ] **Tab bar.** It minimises on scroll on iOS 26. The resume-cooking pill becomes the tab
      bar's bottom accessory on iOS 26, and its own floating glass pill on 17–25. The
      `padding(.bottom, 60)` hack is gone.
- [ ] **Explore.** A large title. Filter chips including "Can make now". New full-bleed recipe
      cards with a glass fit chip ("You have 9 of 10"). Skeleton loading instead of a spinner. A
      branded empty state.
- [ ] **Recipe detail.** A hero cover image. On iOS 18+, the card zooms into the hero
      (`navigationTransition(.zoom)`); older versions use a standard push. Quantities are set in
      SF Rounded. The pantry-fit result has a count-up reveal.
- [ ] **Cooking mode.**
  - The step card fills the screen, with segmented progress and large step text.
  - The tools (Repeat, Slower, Ask, Look) float in a glass cluster. Back/Next form a glass bar.
  - Timers show as rings with a pulse at zero.
  - Step advance uses a push transition, with a haptic only after the server confirms the step.
  - Session complete draws a check in.
  - It still lays out at AX5 Dynamic Type.
- [ ] **Voice.** The empty state, step-complete, error and allergy copy follow the Mise voice.
      Safety wording that Slice 3 locked (DECISIONS #15) is not changed.
- [ ] **App icon.** A vector "leaf-lens" icon with light, dark and tinted variants, in the asset
      catalog.
- [ ] **Accessibility.**
  - Reduce Motion means crossfades only.
  - Increase Contrast is honoured.
  - VoiceOver labels are unchanged or better.
  - No safety message is hidden or auto-dismissed by an animation.
- [ ] **Unchanged.** No behaviour, API or Step Oracle changes. Existing unit tests pass, and the
      5/5 live smoke test passes on iOS 17.5.
- [ ] **CI.** The iOS workflow builds with Xcode 26.2 (selected on the runner). Tests still run
      on an iPhone simulator.
- [ ] **Screenshots.** Before/after screenshots on iOS 26.2 and 17.5, light and dark, for
      Explore, Recipe and Cooking, attached to the PR.

## Out of scope
- Pantry screens, Creator authoring and Profile restyle. They come in PR 2 (brief 006b), and
  until then they just inherit the new tokens.
- Any backend change, and new features.
- Custom fonts, illustration and photography.
- Raising the deployment target above iOS 17.2.

## Open product questions (answered 2026-10-23)
1. **Brand direction?**
   → *Answer:* **Mise**, warm editorial (DECISIONS #17).
2. **iOS target?**
   → *Answer:* **Keep iOS 17.2+.** Liquid Glass on 26, frosted fallback on older versions.
3. **Scope?**
   → *Answer:* **Core loop first.** Explore, Recipe and Cooking now; Pantry, Creator and
     Profile in PR 2.
4. **App icon?**
   → *Answer:* **Eng designs it in code** for the pilot. It is replaceable later.

## Engineering decisions (filled in by the lead while building)
- **Toolchain.** Build with Xcode 26.2 against the iOS 17.2 deployment target. iOS 26 APIs are
  behind `#available` (research: the macos-15 runner has Xcode 26.2, but its default is 16.4).
- **Contrast.** The palette was verified with a WCAG script: the lowest text ratio is 5.3:1, and
  white on herb green is 6.4:1.

## Risks / what could go wrong for users
- **Glass legibility.** Glass over busy food photos can be hard to read. Mitigation: a scrim
  under every glass chip on imagery, and Reduce Transparency gives a solid surface.
- **Two-path drift.** iOS 17 users see the frosted path, which CI doesn't render. Mitigation:
  the live smoke runs on 17.5, and the screenshots cover both versions.
- **Visual-only changes can still break tests.** Accessibility identifiers used by the smoke
  test must be kept.
