# 002 — Slice 0: iOS foundation

**Status:** in review (PR #2) · **Owner:** PM · **PR:** https://github.com/hshwang34/SousLens/pull/2 · **Updated:** 2026-10-20

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
- Swift 6 language mode with strict concurrency kept (no fallback needed). Non-Sendable AV objects
  live inside a private actor / lock-protected delegate bridges.
- `make ios-check` signs ad hoc (`CODE_SIGN_IDENTITY=-`) instead of the brief's
  `CODE_SIGNING_ALLOWED=NO`: an unsigned simulator host app cannot use the Keychain (-34018), so
  the token-store tests would not run. The simulator OS is auto-detected (`ios/scripts/sim-os.sh`)
  because a bare `name=iPhone 15` resolves to the newest runtime, which has no iPhone 15.
- `SousLens.xcodeproj` is gitignored; it is a pure XcodeGen artifact and CI regenerates it.
- Bonjour discovery skipped in Slice 0 (manual URL + simulator default suffice; the backend does
  not advertise yet). Revisit when a physical device joins the pilot.
- Health response no longer carries `auth_mode` (backend hardening); the DTO was trimmed to match.
- Dev sign-in is two-step (email → 6-digit code from the server log → token) per DECISIONS #5 and
  the security review of PR #1; the sign-in screen has a code step.
- `EvidenceOrigin` decodes unknown values to `.unknown`, labelled conservatively as
  "AI-extracted" (never "Creator instructions"), so a new backend origin never breaks a recipe.
- Changing the server URL while signed in signs the user out and clears the recipe cache
  (token must never travel to a different host).
- Screenshots of the gate run live in `docs/product/screenshots/slice0/` for the PM.
- A live XCUITest smoke (`make ios-smoke`, scheme `SousLensSmoke`) is the PRD Slice 0 gate: fresh
  install → email → one-time code read from the backend log → Explore → seeded recipe detail. It is
  not part of `make ios-check` or CI because it needs a running backend.
- Capture adapters use a start-gate/generation pattern so a stop during an awaited permission
  prompt always wins; the camera indicator follows AVCaptureSession notifications, not a flag.
- `summary` is optional on cards and detail (backend declares it nullable).

## Risks / what could go wrong for users
- Simulator cannot test real camera/mic; capture sources must degrade to "unavailable" cleanly.
