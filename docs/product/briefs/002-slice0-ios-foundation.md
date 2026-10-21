# 002 — Slice 0: iOS foundation

**Status:** building · **Owner:** PM · **PR:** — · **Updated:** 2026-10-20

## Problem
No app exists. Slice 0 must prove the SwiftUI shell, API client, dev sign-in, and the device
abstractions (camera/speech/audio protocols) so later slices add features, not plumbing. PRD §16
Slice 0, §6 IA, §9.1, §9.4.

## Who it's for
A tester on an iPhone simulator (and later a device on the same Wi-Fi as the backend).

## What success looks like
- Launch the app in the simulator → sign in with an email → Explore shows the seeded recipe from
  the local backend → tap it → recipe detail with creator, ingredients, steps, cues, warnings.
- Empty states say "Try the demo recipe" / "Add pantry item" (PRD §6.1).

## Acceptance criteria
- [ ] `ios/project.yml` (XcodeGen) → `SousLens.xcodeproj`; app target `SousLens`
      (bundle `com.souslens.ios`, team `V56DG94ZL5`, iOS 17.2+, Swift 6 language mode), test target
      `SousLensTests`. `make ios-check` builds and runs tests on an iPhone 15 simulator with
      `CODE_SIGNING_ALLOWED=NO`.
- [ ] Bottom tabs Explore / Saved / Pantry / Profile (PRD §6). Saved and Pantry are empty-state
      placeholders with the required copy; Profile shows the signed-in user and Sign out.
- [ ] Sign-in screen (email → `POST /v1/auth/dev-login`), JWT stored in Keychain, auto-restored on
      launch; 401 anywhere → back to sign-in.
- [ ] `APIClient` (async/await, `URLSession`) with typed Codable DTOs mirroring the backend's
      canonical recipe JSON, PRD error envelope decoding, `X-Correlation-Id` logging, and a
      `ServerSettings` screen (gear on Profile) to override the base URL
      (default `http://localhost:8000` in simulator). Optional Bonjour `_souslens._tcp` discovery
      ported from Retrace if cheap; otherwise manual only.
- [ ] Explore: list of recipe cards (title, creator, prep+cook time, tags) with search field
      wired to `?query=`; pull to refresh; loading/error/empty states.
- [ ] Recipe detail: hero (placeholder if no photo), creator attribution + version badge,
      ingredients list, numbered steps with success cues and warnings, "Creator instructions" label
      (PRD §13.4). Save / Check my pantry / Start cooking buttons present but disabled with
      "coming in a later build" hints.
- [ ] `Services/Capture`: protocols `CameraSource` (start preview, grab single frame, stop),
      `SpeechInput` (push-to-talk transcript), `AudioOutput` (speak text); concrete
      `PhoneCameraSource` (AVFoundation, permission explainers), `PhoneSpeechInput`
      (SFSpeechRecognizer, permission explainers), `SystemAudioOutput` (AVSpeechSynthesizer).
      Each behind a feature flag and unit-testable via a fake. No DAT SDK in this slice.
- [ ] `DesignSystem/`: color + type tokens in an Asset Catalog (light/dark), Dynamic Type, ≥44pt
      targets, a `RecipeCard` and `MetadataPill` component. Warm, food-friendly palette, not
      Retrace's industrial one.
- [ ] Unit tests: DTO decoding from `fixtures/expected_outputs/recipe_detail.json`,
      `ExploreViewModel` with a fake API, Keychain token store round-trip.
- [ ] `ios/README.md`: how to run, how to point at a LAN backend from a device.

## Out of scope
Pantry capture, authoring, cooking screen, glasses, Gemini Live, TestFlight CI.

## Open product questions
None blocking.

## Engineering decisions (filled in by the lead while building)
- XcodeGen over a hand-maintained pbxproj; project file is regenerated, never edited.
- Minimum iOS 17.2 (PRD §14, DAT sample). No SwiftData yet; a tiny `Persistence/` with
  `Codable` file cache for the recipe list; SwiftData can come in Slice 3 for session cache.
- MVVM with `@Observable`; one `AppEnvironment` injecting `APIClient`, `AuthStore`, capture sources.

## Risks / what could go wrong for users
- Simulator cannot test real camera/mic; capture sources must degrade to "unavailable" cleanly.
