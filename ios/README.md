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
  ingredients used, success cues, warnings, creator note). Swipe to delete; **Reorder** (top right) moves ingredients and steps. Numeric fields commit on every keystroke.
- **Autosave:** every change is PATCHed after an 800 ms debounce (whole form; arrays replace whole,
  steps sent in display order). A field the creator empties (title, summary, servings, prep/cook
  minutes) is sent as JSON `null`, which the backend reads as "clear"; omitted keys mean "unchanged".
  Steps keep their original provenance (`evidence_origin`, source clip) when edited.
- **Text rules:** fields cap at the backend's limits as you type (`DraftLimits`: title 120,
  summary 1000, tag 40, ingredient name 200 / unit 32 / preparation 200 / notes 500, instruction
  2000, notes/warnings/cues 500). Before sending, `DraftText` strips control and bidi characters,
  turns newlines in single-line fields into spaces, trims, and lowercases + dedupes tags. If the
  server still refuses a PATCH (422), the bar shows "Couldn’t save · <server reason>" with no Retry;
  the next edit saves again. The bar shows **Saving… / Saved / Couldn’t save · Retry**. Closing
  with an unsaved change asks before discarding.
- **Validation:** the server's `validation.problems` are shown inline next to the field or row
  (`title`, `ingredients`, `steps[1].instruction`, …). **Publish** is enabled only when the last
  saved state has `validation.publishable == true`.
- **Publish:** always behind a confirmation sheet ("Publish version N? This snapshot can’t be
  edited; later edits create a new version"). Pending edits are saved first; a failed save blocks
  the publish. If the publish request fails in transit, the app re-reads the draft and reports
  success if it was in fact published. Success shows the version, the share link and a share sheet.
- **Share links are always built from the recipe id** (`ShareLinks`); the server's `share_url` is
  never shown or shared.
- **Preview** renders the draft through the real detail layout under a "Draft preview" banner.
- **Edit a published recipe:** owner sees **Edit** / **Unpublish** on the detail screen. Edit calls
  `POST /v1/recipes/{id}/edit`; a 409 means a draft is already open and that draft is opened
  instead. A PATCH that returns 409 (draft already published) turns the editor read-only: fields are
  disabled, nothing more is sent, and Close does not ask about unsaved changes.
- **Profile** lists *My recipes* (visibility pill, version, "Draft in progress"; swipe to Unpublish
  with confirmation) and *Drafts* (tap to continue, swipe to delete with confirmation).
- **Save:** Save/Unsave on the detail screen flips immediately and rolls back with an inline message
  if the idempotent POST/DELETE fails. The **Saved** tab is `GET /v1/me/saved` and refreshes
  whenever a save changes anywhere in the app.
- **Share / deep links:** `souslens://recipe/{id}` (registered in `CFBundleURLTypes`) and
  `https://souslens.app/r/{id}` (exact host only; associated-domains entry is a stub, the domain is not live) both
  open the recipe on the Explore stack from any tab. A link that arrives while signed out is
  applied after sign-in. Try it: `xcrun simctl openurl booted souslens://recipe/<recipe-id>`.
- Search placeholder is "Search recipes or ingredients" (the backend matches title or ingredient).

## Slice 2: pantry capture and fit (brief 004)

- **My Pantry** (`Features/Pantry`): `GET /v1/pantry`, sorted by name. Each row shows a provenance
  badge (**Manual / Voice / Photo**), quantity (photo counts carry an *estimate* marker), location
  and "Confirmed N days ago". More than 14 days since the last confirmation adds **Check this** and
  a **Still have it** button (`POST /v1/pantry/{id}/confirm`; also a leading swipe). Tap a row to
  edit (PATCH sends every editable field; a cleared field goes as JSON `null`); swipe left →
  Delete, always behind a confirmation. The empty state keeps **Add pantry item** and **Try the
  demo recipe**. Toolbar: **Speak**, **Scan**, **Add**.
- **Speak**: hold the mic button to listen through `PhoneSpeechInput`. While it is on, a
  "Listening… (iPhone microphone)" pill and the live transcript are visible; release stops audio
  at once (the gesture state also resets if the system cancels the touch, and backgrounding stops
  it). The transcript stays editable, then **Find items** posts a transcript observation.
  **Type instead** is always there and feeds the same call, so the flow works without a mic,
  without permission and in the simulator (where the sheet opens straight in typing mode).
  VoiceOver: double-tap toggles listening ("Listening until you tap Stop", auto-stop after 60 s).
  Press and release share one start gate, so a tap released before the mic has started never
  leaves it on. **Provenance:** text that was dictated (even if edited afterwards) is saved as
  `voice`; text that was only typed is `manual`; photos are `photo`. An unknown server source
  shows an "Other" badge. A 503 `PROVIDER_UNAVAILABLE` / 502 `AI_OUTPUT_INVALID` shows "Couldn’t
  read that right now — try again" with **Retry**, keeping the text or photo in memory.
- **Scan**: **Start camera** (explicit tap) runs `PhoneCameraSource` with a live viewfinder and a red
  **Camera on** badge; **Take photo** grabs one frame and stops the camera immediately. **Choose
  photo** (PhotosPicker, no library permission needed) is the same path. The photo is previewed,
  downscaled to a 1600 px long edge and re-encoded as JPEG ≤ 5 MB in memory
  (`PantryImageEncoder`, which also drops EXIF), then sent as `multipart/form-data`
  (`mode=photo`, `image`). It is never written to disk; it is dropped once the server answers (on
  a failed request it stays in memory for a retry until the sheet closes).
- **Scan review**: one row per candidate with editable name / quantity / unit, the confidence bin
  as an estimate (**Likely / Maybe / Not sure**), the evidence text and an accept checkbox ("Not
  sure" and `action: ignore` start unticked). Unknowns get their own section. Mock photo results
  show **Demo mode — not a real detection** and every candidate starts unticked (opt in).
  An expired scan (`expires_at` passed, or 404/410 on confirm) says "This scan expired — scan
  again"; 409 `STATE_CONFLICT` (already confirmed) says "These items were already added" and
  closes. Quantities must be > 0. A candidate with `duplicate_of` shows "You already
  have X" with **Merge / Keep both**; Confirm stays disabled until each is answered. A 409
  `DUPLICATE_PANTRY_ITEM` re-opens that choice for exactly the rows in `details.conflicts` and
  sends nothing more until the user answers. Confirm posts only the ticked rows plus the
  `observation_id`. The manual add sheet handles a 409 the same way (Merge / Keep both / Cancel).
- **Pantry fit** (`Features/Recipe/PantryFitView`): **Check my pantry** on recipe detail posts
  `/v1/recipe-versions/{version_id}/fit` for the version on screen. Sections **Available /
  Uncertain / Missing / Optional**, each line with the server's reason sentence (plus any
  conversion note). The headline is **Can make it** only when `can_make` is true *and* no
  required line is uncertain or missing; otherwise "You’re missing N" or "Check N items". Coverage
  reads "X of Y ingredients" (required only), never as a guarantee. Missing lines offer **Add to
  pantry** (manual sheet, name prefilled only); stale matches offer **Still have it**; a match
  whose amount is a photo estimate offers **Fix amount** (opens the editor). Every change re-runs
  the fit once (via `pantryRevision`; the last request wins). VoiceOver reads each row's status
  as one element; its buttons follow as separate buttons named "<action>: <ingredient>". Edits PATCH only the fields that changed; an
  unrecognised storage location is kept as is.
- Debug builds only: launch with `-pantry.photoFixture gochujang_jar` to send `fixture=<stem>` with
  photos (honoured by the backend only when `AI_PROVIDER=mock`).

## Slice 3: substitutions and cooking (brief 005)

All state lives on the server (Step Oracle). The app sends commands and renders whatever Session
comes back; it never moves a step, starts a timer or applies a swap on its own.

- **Allergies & foods to avoid** (Profile → Cooking): chips with add/remove, saved on each tap
  (`PUT /v1/me/preferences`, rolled back on failure; the server's normalised names replace
  ours). Allergies block swaps; "avoid" is a preference. The copy never says anything is "safe".
- **Find a swap** (Pantry fit, required Missing and Uncertain lines): `POST /v1/substitutions/suggest`
  → up to three cards with candidate, amount, why, flavour/texture impact, confidence in words,
  risks, allergy warning and a label derived from `source` (**Common swap** = vetted rule,
  **AI suggested adaptation** = anything else, including unknown sources). **Use this swap** is
  the only approval; **No thanks** closes. `cannot_substitute` (or no suggestions) shows the reason
  with **Keep it missing** / **Find another recipe** (Explore). Approved swaps are held on the fit
  screen, shown on their row with **Undo swap**, summarised above **Start cooking**, and sent only
  in `POST /v1/sessions`. **Use my changes from last time** appears when
  `GET /recipe-versions/{id}/my-variation` returns one; tapping it fills the swaps (still undoable).
- **Start cooking** (fit screen with swaps, or recipe detail as written) creates the session and
  opens the full-screen cooking view, which sends `start` on that same tap.
- **Cooking** (`Features/Cooking`): step N of M, the session's step text in large Dynamic Type,
  **Adapted · Common swap / AI suggested adaptation** badge with **Show original**, success cues,
  warnings with a safety icon, creator note, "No clip for this step", oversized **Back / Pause /
  Next** (Next becomes **Finish** on the last step), **Repeat**, **Slower**, **Ask**, and a disabled
  **Look** ("coming with camera help"). The menu has *Read steps aloud*, *Undo a swap* (sends
  `revert_adaptation`) and *Stop cooking…* (confirmation → `abandon`).
- **Commands**: each tap is one `POST /v1/sessions/{id}/commands` with `user_confirmed: true`,
  the current `revision` as `expected_revision`, and a fresh `Idempotency-Key`
  (`SessionCommandSender`). If the outcome is unknown (no response, 5xx) the key and body are kept
  and **Reconnect** re-sends them unchanged, so a lost response never advances twice. 409
  `STATE_CONFLICT` adopts `details.session` and shows "Updated from your other device"; 409
  `INVALID_TRANSITION` adopts it too. Nothing is re-sent automatically.
- **Read aloud** (`SystemAudioOutput`) only after an explicit Start / Next / Back / Repeat /
  Slower (Slower reads at a lower rate). Opening, resuming, pausing and timers never speak.
- **Timers**: a step's `suggested_timer` is offered as "Start a 10-min simmer timer?" with
  **Start / Skip**; Start sends `start_timer`. Running timers count down from the server's absolute
  `target_at` every second, so they are right after a relaunch; past-target timers read **Done**.
  Cancel sends `cancel_timer`.
- **Assistant drawer** (Ask): typed questions (≤ 500 chars) → `POST /sessions/{id}/ask` with
  `grounded_revision`. Answers split "The recipe says … / My suggestion" as returned, grounding
  badges (Step N, Creator note, Ingredient, Your swap), uncertainty in words, safety notice styling,
  **Based on previous step** when the server says stale or the step has moved, and **Read aloud**.
  A `proposed_action` is a button ("Go to next step?"); only a tap sends it, as a confirmed
  command with `client_source: ios_assistant`. 429 says to try again later.
- **Session end**: Cooked it / Partly / Didn't work, a private note (`POST /notes`), and **Save my
  changes** (only when the session has swaps; off by default). **Done** sends the note, then
  `complete` with the outcome.
- **Resume**: on launch and every return to the foreground, `GET /v1/sessions?status=active` →
  banner "Continue cooking <title> — Step N" (dismissible), then a floating pill while browsing.
  Tapping reopens the cooking view at the server's step. Offline, the last cached Session is shown
  read-only with **Reconnect to continue**.
- **Account isolation**: the cached Session (`Persistence/SessionCache`) is stamped with the owner
  (user id + server) and deleted if anyone else reads it. Every AuthStore path that drops
  credentials (sign-out, 401, server change, fresh install, a restore that ends signed out, a
  different user signing in) resets `CookingSessionStore`, which bumps an epoch so late results are
  dropped and invalidates the open cooking view model.

### Permissions

The camera and microphone are requested the first time you tap **Start camera** or hold the mic,
with the purpose stated on screen right before it (PRD §13.2). Usage strings live in
`project.yml` (`NSCameraUsageDescription`, `NSMicrophoneUsageDescription`,
`NSSpeechRecognitionUsageDescription`). If a permission is denied, the screen shows why it is
needed, an **Open Settings** button and the alternative (**Type instead** / **Choose photo**).

## Tests

```bash
make ios-check                   # xcodegen generate + xcodebuild test on "iPhone 15" (SIM=... to override)
make ios-smoke                   # live XCUITests (needs `make backend-dev` + `make seed`); not in ios-check
```

`SousLensSmoke` (separate scheme, never in `SousLens`) has five tests: sign in → open the seeded
recipe; `testAuthorPublishAndSave` (Profile → Create recipe → title, one ingredient, one step →
Publish → confirm → find it via Explore search → Save → see it in Saved); and
`testTypeIntoPantryAndCheckFit` (Pantry → Speak → Type instead → "chicken thighs, two onions,
gochujang and honey" → Find items → Add → Explore → Gochujang Chicken Thighs → Check my pantry →
gochujang is matched, something is Missing/Uncertain); `testSwapAndCookToCompletion` (type
"3 tbsp gochujang, 2 lb chicken thighs" → Gochujang Chicken Thighs → Check my pantry → Find a swap
on rice vinegar → Use this swap → Start cooking → Next through every step, seeing the Adapted badge
→ ask "what does this step mean?" and see a step badge → Finish → Cooked it + Save my changes →
Done); and `testResumeAfterRelaunch` (Start cooking → Next twice → terminate → relaunch → the
banner says Step 3 → tap → cooking screen at step 3). Each signs in with its own email (the
pantry test uses a fresh timestamped one so its pantry starts empty) and only accepts a code
logged after it tapped Continue.

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
  Features/       Explore, Recipe (detail, pantry fit, swap sheet), Cooking (cooking screen,
                  assistant drawer, session end, resume banner/pill), Creator (draft editor, ingredient/step
                  editors, publish confirmation, preview), Saved, Pantry, Profile (my recipes,
                  drafts, sign-in, server settings)
  Models/         Codable DTOs mirroring the backend's snake_case JSON
  Services/API    APIClient (async/await, PRD error envelope, X-Correlation-Id logging), ServerSettings
  Services/Auth   AuthStore (@Observable), KeychainTokenStore (Security framework)
  Services/Capture CameraSource / SpeechInput / AudioOutput protocols, phone adapters, fakes
  Persistence/    RecipeCache (Explore offline), SessionCache (owner-stamped last Session)
  Services/Cooking SessionCommandSender (idempotency keys), CookingSessionStore (resume, epoch)
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
  session stops when the app enters the background. The pantry-scan viewfinder
  (`CameraPreviewView`, an `AVCaptureVideoPreviewLayer` on `CameraPreviewProviding.previewSession`),
  the real "take photo → camera off" timing, the camera permission prompt and the HEIC → JPEG
  path for camera frames are **device-only**; the simulator shows **Choose photo** only.
- Pantry speech: the push-and-hold gesture, the live "Listening… (iPhone microphone)" pill, the
  final transcript after release and the mic/speech permission prompts are device-only; the
  simulator opens Speak in typing mode. The view-model logic is unit-tested with
  `FakeSpeechInput` / `FakeCameraSource`.
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
