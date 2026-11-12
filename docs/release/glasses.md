# SousLens Glasses — install, test, and the path to release

Brief 009 (Slice 6). DECISIONS #18–#19: the glasses build goes **to the PM only, through Meta
Developer Mode**. The public TestFlight/App Store app (**SousLens**) does not link the Meta
Wearables Device Access Toolkit (DAT) at all. `make ios-check` fails if it ever does
(`ios/scripts/check-no-dat.sh`).

| | SousLens (public) | SousLens Glasses (PM only) |
|---|---|---|
| Scheme / target | `SousLens` | `SousLensGlasses` |
| Bundle id | `com.souslens.ios` | `com.souslens.ios.glasses` |
| Home-screen name | SousLens | SousLens Glasses |
| DAT 1.0.1 (MWDATCore, MWDATCamera) | not linked | linked |
| ExternalAccessory, `MWDAT` plist keys | none | yes |
| URL scheme | `souslens://` (share links) | `souslensglasses://` (Meta AI callbacks only) |
| Compilation condition | — | `GLASSES` |

The bundle ids differ, so **both apps can be installed side by side**. Each has its own Keychain
group, so you sign in to each one separately. Share links (`souslens://recipe/…`) open the public
app; the glasses app doesn't claim that scheme.

---

## 1. Install the glasses build on your iPhone

You need: a Mac with Xcode 26.2, your iPhone (iOS 17.2 or later; **iOS 26 recommended**, see
Risks), a USB cable or the same Wi-Fi, your Apple ID in the personal team **V56DG94ZL5**, and the
Meta AI app signed in with the Meta account that owns the glasses.

### Option A — run from Xcode (simplest)

1. `cd ~/Documents/Projects/SousLens && make ios-project` (generates `ios/SousLens.xcodeproj`).
2. Open `ios/SousLens.xcodeproj`. Pick the **SousLensGlasses** scheme and your iPhone as the
   destination.
3. Signing is automatic with team V56DG94ZL5 (Signing & Capabilities shows it). The first time,
   Xcode registers `com.souslens.ios.glasses` and your device in the personal team.
4. **Run** (⌘R). On the phone, the first launch may need Settings → General → VPN & Device
   Management → trust the developer, and **Developer Mode** for iOS (Settings → Privacy & Security
   → Developer Mode) if you haven't turned it on before.
5. In the app: Profile → Server settings → point it at your backend, then sign in.

A development-signed build runs until its profile expires (about a year for a paid account).

### Option B — internal TestFlight (no cable afterwards)

Internal testers only (members of the App Store Connect team, no Beta App Review). Never add this
build to an external group or the public link: that's the public app's channel.

1. In App Store Connect, create a **second app record** for `com.souslens.ios.glasses`
   ("SousLens Glasses"). It stays unreleased.
2. Xcode → scheme **SousLensGlasses** → destination *Any iOS Device* → Product → **Archive** →
   Distribute App → App Store Connect → Upload. (Each upload gets a one-line PM confirmation per
   DECISIONS #18.)
3. TestFlight → Internal Testing → add yourself → install from the TestFlight app.

Meta's terms currently don't allow distributing DAT apps beyond developers and invited testers, so
keep it internal (see §4).

## 2. Turn on Developer Mode in Meta AI

1. Update the glasses firmware and Meta AI first.
2. Meta AI → **Settings → Your glasses (Devices) → Developer Mode → On.** (On some versions it's
   under the glasses' settings → *Developer Mode*; tapping the version number reveals it.)
3. Developer Mode lets an app with `MetaAppID = 0` register without a Wearables Developer Center
   app. **A glasses firmware update can switch it off.** If registration or streaming suddenly
   fails after an update, check this switch first, then re-register (step 3 below).

## 3. Register and allow the camera

1. Wear or unfold the glasses, connected to Meta AI as usual.
2. SousLens Glasses → **Profile → Glasses → Register with Meta AI.** Meta AI opens, asks you to
   approve, then returns to the app through `souslensglasses://`. Status: **Registered**.
3. **Allow glasses camera.** Meta AI opens again for the camera permission. Status: **Allowed**.
4. The Device section shows live state: *Connecting… / Connected / Streaming / Paused / Glasses
   folded / Glasses battery low / Glasses too warm*, plus the battery level.
5. **Start preview** shows a small live view with a red **Glasses camera on** badge. Leaving the
   screen or backgrounding the app stops it.

## 4. Manual test checklist (run once with the PM, then after each firmware/Meta AI update)

Record the result and versions in §6.

- [ ] Fresh install → Profile → Glasses shows *Not registered*. Nothing streams, no badge.
- [ ] Register → Meta AI round-trip → *Registered*. Allow camera → *Allowed*.
- [ ] Device state follows reality: take the glasses off / fold / unfold / put them on the charger.
- [ ] Settings preview: Start → frames + **Glasses camera on** badge; Stop → badge gone.
- [ ] **Pantry scan via glasses:** Pantry → Scan. The picker shows *iPhone camera / Glasses
      camera* (glasses only when ready). Choose Glasses → Start camera → the badge reads
      **Glasses camera on** → look at a shelf → Take photo → the camera stops at once → Find
      items → the review screen lists candidates (same backend call as the iPhone camera).
- [ ] **Fold the glasses mid-scan:** the badge goes off, a banner says *Glasses camera unavailable.
      The glasses are folded. Using the iPhone camera.*, and Start camera now uses the iPhone.
      Unfold → the Glasses option returns; nothing restarts by itself.
- [ ] **Fold the glasses mid-cook:** with a cooking session open on step N, fold them, wait 10 s,
      unfold. The session is still open on step N (not ended, not advanced), the resume banner/pill
      is unchanged.
- [ ] Turn the glasses off mid-stream: same fallback and banner; no crash.
- [ ] Deny the camera permission in Meta AI → the Glasses option disappears; Settings shows *Not
      allowed* with **Allow glasses camera**.
- [ ] **Mic label:** Profile → Glasses → Microphone reads *iPhone microphone* when nothing is
      routed. Start Speak (hold the button) with the glasses connected: the label reads
      *Glasses microphone* **only** if iOS routes the glasses' Bluetooth headset (HFP) mic.
      Play music to the glasses (A2DP only) → the label must stay *iPhone microphone*.
      AirPods → *Bluetooth microphone (AirPods…)*, never "glasses".
- [ ] Background the app while streaming → stream stops; back to foreground → nothing restarts.
- [ ] The public SousLens app installed alongside still works and has no Glasses section.

## 5. The full path to wider release (when Meta opens distribution)

Today: Developer Mode only (`MetaAppID = 0`). When Meta allows distribution of DAT apps, follow
this order. Each step that ships to people outside the PM needs a fresh PM go.

1. **Wearables Developer Center project.** Sign in at wearables.developer.meta.com with a
   *personal* Meta developer account (never an `@augmend.health` identity). Create an
   organization (personal), then a project "SousLens" → iOS app with bundle id
   `com.souslens.ios.glasses` (or `com.souslens.ios` if the glasses feature is folded into the
   main app at GA) and Team ID `V56DG94ZL5`.
2. **Application ID and Client Token.** The project page shows the **Meta App ID** and
   **Client Token**. Store the token like a secret (it identifies the app, but keep it out of git
   history; inject it from an xcconfig that's gitignored or a CI secret).
3. **Universal Link + AASA.** Meta AI calls back via a universal link instead of the custom scheme.
   - Host `/.well-known/apple-app-site-association` on the product site (already reserved with the
     right `Content-Type` in `site/vercel.json`, brief 011), e.g.
     `{"applinks":{"details":[{"appIDs":["V56DG94ZL5.com.souslens.ios.glasses"],"components":[{"/":"/glasses/*"}]}]}}`.
   - Register that universal link (e.g. `https://<site>/glasses/callback`) as the app link in the
     Developer Center project.
4. **Associated Domains.** Add `applinks:<site host>` to the glasses target's entitlements in
   `ios/project.yml` (the public target already has `applinks:souslens.app` as a stub), and route
   `/glasses/*` URLs to `Wearables.shared.handleUrl` in `DATGlassesController.handleOpenURL`.
5. **Info.plist changes** (glasses target, `ios/project.yml`):

   | Key | Developer Mode (now) | Released |
   |---|---|---|
   | `MWDAT.MetaAppID` | `"0"` | the Meta App ID |
   | `MWDAT.ClientToken` | `""` | the Client Token (from xcconfig/CI secret) |
   | `MWDAT.TeamID` | `$(DEVELOPMENT_TEAM)` = V56DG94ZL5 | unchanged |
   | `MWDAT.AppLinkURLScheme` | `souslensglasses://` | the universal link, e.g. `https://<site>/glasses/callback` |
   | `CFBundleURLTypes` `souslensglasses` | needed | can be removed once the universal link works |
   | `MWDAT.Analytics.OptOut` | `true` | decide with the privacy policy (default stays opt-out) |

   DAT 1.0.1 logs *"Partial attestation configuration detected"* if only one of ClientToken/TeamID
   is set; with the real token both are present and App Attest runs (needs network).
6. **Beta release channel (Meta).** In the Developer Center project, create a release channel
   "Beta", **invite testers by the email of their Meta account** (cap about 100). Testers accept
   in Meta AI; without that, registration fails for them even with the app installed.
7. **Internal TestFlight** with the released config (§1 Option B), PM + invited testers who are on
   the Meta Beta channel.
8. **External TestFlight / App Store GA.** Only after Meta permits public DAT distribution *and*
   Apple review accepts the ExternalAccessory use (`UISupportedExternalAccessoryProtocols`
   `com.meta.ar.wearable`, MFi). Decide then whether glasses ship in the main app (merge the
   flavours; App Review notes must explain the accessory) or stay a separate app. Promote the Meta
   release channel to production at the same time.

## 6. Version matrix (fill in after each manual run)

| Date | SousLens Glasses build | DAT iOS | iOS | iPhone | Glasses model | Glasses firmware | Meta AI app | Result / notes |
|---|---|---|---|---|---|---|---|---|
| | 0.1.0 (1) | 1.0.1 | | | | | | |

## Implementation notes

- DAT APIs used (all non-experimental): `Wearables.configure()`, `Wearables.shared`
  (`registrationState`, `addRegistrationStateListener`, `startRegistration`, `startUnregistration`,
  `handleUrl`, `checkPermissionStatus(.camera)`, `requestPermission(.camera)`, `devices`,
  `addDevicesListener`, `deviceForIdentifier`, `createSession(deviceSelector:)`),
  `AutoDeviceSelector`, `Device.addDeviceStateListener` / `nameOrId()`, `DeviceSession.start()` /
  `stop()` / `statePublisher` / `errorPublisher`, `DeviceSession.addCamera(config:)`,
  `Camera.stop()`, `Camera.stream` (`start()`, `statePublisher`, `errorPublisher`,
  `videoFramePublisher`), `VideoFrame.makeUIImage()`, `StreamConfiguration(videoCodec: .raw,
  resolution: .medium, frameRate: 15)`. Not used: `Camera.photo`, camera audio, Speech, Inputs,
  Motion, Display.
- A scan frame is the latest stream frame at the tap, JPEG-encoded in memory, then the stream and
  session stop and the frame is dropped. It goes to the same `POST /v1/pantry/observations` call
  as an iPhone photo.
- Every DAT stream/session error and device state (hinges, heat, battery, disconnect) changes only
  camera availability plus a banner. `DATGlassesController` holds no reference to the cooking
  store.
- Info.plist keys are the ones MWDATCore 1.0.1 checks at runtime (`NSBluetoothAlwaysUsageDescription`,
  `NSLocalNetworkUsageDescription`, `NSBonjourServices` incl. `_meta-datax._tcp`, `UIBackgroundModes`
  `bluetooth-central` + `external-accessory`, `UISupportedExternalAccessoryProtocols`
  `com.meta.ar.wearable`); MockDeviceKit enforces the same check.
- Tests: `make ios-check-glasses SIM="iPhone 16e"` (MockDeviceKit). Add
  `GLASSES_SHOTS=<folder>` to regenerate the screenshots.

## Risks

- DAT is a developer preview: Meta AI or firmware updates can break registration or streaming.
  The iPhone camera path always works, and this matrix pins what was last verified.
- Developer Mode can switch off after a firmware update (§2).
- **iOS 17 runtime:** on the iOS 17.5 simulator, the XCTest host crashed while enumerating classes
  inside MWDATCore (Swift metadata for a type that only exists on newer iOS). The glasses tests
  therefore run on an iOS 26 simulator. Use an iPhone on iOS 26 for the glasses build.
- Apple review of ExternalAccessory use is unknown until GA; the public app avoids it entirely.
