# SousLens iOS

SwiftUI app (iOS 17.2+, Swift 6 language mode, no third-party packages). The Xcode project is
**generated** from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen); never edit
`SousLens.xcodeproj` by hand (it is gitignored).

## Run it

```bash
brew install xcodegen            # once
make ios-project                 # regenerates SousLens.xcodeproj from ios/project.yml
open ios/SousLens.xcodeproj      # pick an iPhone simulator, ⌘R
```

Start the backend first so there is something to sign in to:

```bash
make db-up && make backend-dev   # FastAPI on http://localhost:8000, AI_PROVIDER=mock
make seed                        # loads the demo recipe
```

Sign in with any email (dev auth creates the account). It is a two-step flow: after **Continue**,
**watch the backend terminal for the 6-digit code** (the server logs it instead of sending mail),
type it on the code screen and tap **Verify**. Codes expire after the server's `expires_in_seconds`
(10 minutes by default); a wrong or expired code shows "Invalid or expired sign-in code" inline and
keeps you on the code step. Explore then lists the seeded recipes; tap one for ingredients, steps,
cues and warnings.

## Slice 1: author, publish, save, share (brief 003)

- **Create:** Profile → **Create recipe** opens the editor on a new server draft
  (`POST /v1/recipes/drafts`). Title, summary, tag chips, servings stepper, prep/cook minutes;
  ingredients (name, quantity, unit, optional, preparation, notes) and steps (instruction, minutes,
  ingredients used, success cues, warnings, creator note). Swipe to delete, **Edit** to reorder.
- **Autosave:** every change is PATCHed after an 800 ms debounce (whole form; arrays replace whole,
  steps sent in display order). The bar shows **Saving… / Saved / Couldn’t save · Retry**. Closing
  with an unsaved change asks before discarding.
- **Validation:** the server's `validation.problems` are shown inline next to the field or row
  (`title`, `ingredients`, `steps[1].instruction`, …). **Publish** is enabled only when the last
  saved state has `validation.publishable == true`.
- **Publish:** always behind a confirmation sheet ("Publish version N? This snapshot can’t be
  edited; later edits create a new version"). Pending edits are saved first; a failed save blocks
  the publish. Success shows the version, the `share_url` and a share sheet.
- **Preview** renders the draft through the real detail layout under a "Draft preview" banner.
- **Edit a published recipe:** owner sees **Edit** / **Unpublish** on the detail screen. Edit calls
  `POST /v1/recipes/{id}/edit`; a 409 means a draft is already open and that draft is opened
  instead. A PATCH that returns 409 (draft already published) turns the editor read-only.
- **Profile** lists *My recipes* (visibility pill, version, "Draft in progress"; swipe to Unpublish
  with confirmation) and *Drafts* (tap to continue, swipe to delete with confirmation).
- **Save:** Save/Unsave on the detail screen flips immediately and rolls back with an inline message
  if the idempotent POST/DELETE fails. The **Saved** tab is `GET /v1/me/saved`.
- **Share / deep links:** `souslens://recipe/{id}` (registered in `CFBundleURLTypes`) and
  `https://souslens.app/r/{id}` (associated-domains entry is a stub; the domain is not live) both
  open the recipe on the Explore stack from any tab. A link that arrives while signed out is
  applied after sign-in. Try it: `xcrun simctl openurl booted souslens://recipe/<recipe-id>`.
- Search placeholder is "Search recipes or ingredients" (the backend matches title or ingredient).

## Tests

```bash
make ios-check                   # xcodegen generate + xcodebuild test on "iPhone 15" (SIM=... to override)
make ios-smoke                   # live XCUITests (needs `make backend-dev` + `make seed`); not in ios-check
```

`SousLensSmoke` (separate scheme, never in `SousLens`) has two tests: sign in → open the seeded
recipe, and `testAuthorPublishAndSave` (Profile → Create recipe → title, one ingredient, one step →
Publish → confirm → find it via Explore search → Save → see it in Saved). Each signs in with its own
email and only accepts a code logged after it tapped Continue.

The Makefile signs the simulator build ad hoc (`CODE_SIGN_IDENTITY=-`). That needs no Apple
certificate, but it does embed the `keychain-access-groups` entitlement that the simulator Keychain
requires; a fully unsigned build (`CODE_SIGNING_ALLOWED=NO`) makes `KeychainTokenStoreTests` fail with
`errSecMissingEntitlement (-34018)`.

The Makefile picks the newest installed runtime that has a simulator named `$(SIM)` (a bare
`name=` destination resolves to `OS:latest`, which fails when that model only ships with an older
runtime). Override either: `make ios-check SIM="iPhone 17"` or `make ios-check SIM_OS=17.5`.
The deployment target is 17.2, so an iOS 17.0 runtime will not work.

## Pointing a physical iPhone at the backend

The simulator shares the Mac's network, so the default `http://localhost:8000` just works. A real
phone cannot see `localhost`:

1. Put the phone and the Mac on the same Wi‑Fi.
2. Find the Mac's LAN address: System Settings → Wi‑Fi → Details, or `ipconfig getifaddr en0`.
3. Make sure the backend listens on all interfaces (`uvicorn --host 0.0.0.0 --port 8000`; `make backend-dev` does).
4. On the phone, open the app → sign-in screen → **Change** (or Profile → gear) and enter
   `http://<mac-ip>:8000`, then **Test connection**. It should report `Connected · v0.1.0 · AI mock · auth dev`.

`Info.plist` sets `NSAllowsLocalNetworking` so plain `http://` to a LAN address is allowed; anything
off-LAN must be `https://`.

On a device, the app starts with **no** server configured and asks for one; the setting persists in
`UserDefaults` (`serverBaseURL`).

## Layout

```
SousLens/
  App/            SousLensApp, AppEnvironment (composition root), RootView (sign-in vs tabs)
  App/DeepLink    souslens:// and souslens.app/r/{id} parsing (`DeepLink`, `ShareLinks`)
  Features/       Explore, Recipe (detail + view model), Creator (draft editor, ingredient/step
                  editors, publish confirmation, preview), Saved, Pantry, Profile (my recipes,
                  drafts, sign-in, server settings)
  Models/         Codable DTOs mirroring the backend's snake_case JSON
  Services/API    APIClient (async/await, PRD error envelope, X-Correlation-Id logging), ServerSettings
  Services/Auth   AuthStore (@Observable), KeychainTokenStore (Security framework)
  Services/Capture CameraSource / SpeechInput / AudioOutput protocols, phone adapters, fakes
  Persistence/    RecipeCache (JSON file; Explore shows cached cards offline)
  DesignSystem/   SLColor / SLFont / Spacing tokens, RecipeCard, MetadataPill, EmptyStateView
  Resources/      Assets.xcassets (light/dark color tokens), generated Info.plist, entitlements
SousLensTests/    unit tests + Fixtures/ (recipe_detail.json, recipes_list.json)
```

## Capture adapters: what the simulator cannot prove

`PhoneCameraSource`, `PhoneSpeechInput` and `SystemAudioOutput` compile and are constructed on
the simulator, but the camera and speech paths report `isAvailable = false` there. The following
behaviours are **device-only** and must be checked on an iPhone before Slice 4 relies on them:

- Speech: the final transcript after releasing push-to-talk (`stop()` calls `endAudio()` and keeps
  the stream open for up to `finalResultGrace`, 1.5 s, for the `isFinal` chunk); teardown on
  `AVAudioSession` interruption (phone call, Siri) and on a headset/glasses connect or disconnect
  (`routeChangeNotification` with `oldDeviceUnavailable` / `newDeviceAvailable`); a failed start
  removing the tap, stopping the engine and deactivating the session; a `stop()` that arrives
  while `startListening()` is suspended in the permission prompt wins (the start tears down and
  throws `CaptureError.cancelled` before any stream opens). The generation and grace-period logic
  is unit-tested through `TranscriptRelay` and the start token through `CaptureStartGate`; the
  real permission-prompt race needs a device.
- Camera: `activeIndicator` follows `AVCaptureSession` notifications (`didStartRunning`,
  `didStopRunning`, `wasInterrupted`, `interruptionEnded`, `runtimeError`) and `isRunning`, and the
  session stops when the app enters the background. **No preview surface
  (`AVCaptureVideoPreviewLayer`) is exposed in Slice 0**; `startPreview()` runs the session so
  `captureFrame()` can grab a JPEG. The pantry-scan screen adds the preview.
- Audio output: `AVSpeechSynthesizer` works on the simulator; interruption/stop behaviour is
  unit-tested (`CaptureTests`).

## Simulator notes

- Camera and speech recognition report `isAvailable = false` on the simulator; the Profile tab
  shows the live state. Speech output (`AVSpeechSynthesizer`) works everywhere.
- Capture adapters sit behind `UserDefaults` feature flags (`feature.capture.phoneCamera`,
  `feature.capture.phoneSpeech`, `feature.capture.systemAudio`, default on); off → the fake adapter
  is injected.
- Logs: `os.Logger` subsystem `com.souslens.ios`, categories `api`, `auth`, `editor`, `camera`, `speech`.
  Filter in Console.app or `xcrun simctl spawn booted log stream --predicate 'subsystem == "com.souslens.ios"'`.
