# 009 — Slice 6: Meta glasses (Developer Mode, PM's device)

**Status:** approved · **Owner:** PM · **PR:** — · **Updated:** 2026-10-28

## Problem
Cooking with your hands full is the reason glasses exist. The PRD's demo shows the same pantry
scan and step inspection through the glasses camera and audio.

## Who it's for
The PM's own Ray-Ban/Oakley Meta glasses (DECISIONS #19). Public testers get the phone-only build.

## What success looks like
On the PM's phone, the glasses build registers with Meta AI (Developer Mode) and shows live
device state. It uses the glasses camera for pantry scan and Look, through the same backend
service as the iPhone camera. Folding the glasses never ends or advances a cooking session.

## Acceptance criteria
- [ ] DAT iOS SDK **1.0.1** via SPM (MWDATCore and MWDATCamera; MockDevice in tests only). No
      experimental APIs (`Camera.photo`, Speech, Inputs, Motion): pantry and Look frames come from
      the stream.
- [ ] Two build flavours from `project.yml`: **SousLens** (public, DAT not linked, no
      ExternalAccessory) and **SousLens Glasses** (DAT linked, `MetaAppID=0`, custom URL scheme,
      Bluetooth and local-network keys). CI builds both.
- [ ] A `GlassesCameraSource` behind the existing `CameraSource` protocol, with the start gate and
      generation counter pattern. Registration, permission, preview and frame selection are
      user-initiated and visibly indicated.
- [ ] Device states (connecting, streaming, paused, hinges closed, battery or thermal) map to
      capture availability only. A disconnect falls back to the iPhone camera with a banner, and
      session state is untouched.
- [ ] Audio: the "glasses microphone" label appears only when `AVAudioSession.currentRoute` shows a
      Bluetooth HFP input, and updates on route change. Otherwise the iPhone mic is used and named.
- [ ] MockDeviceKit tests cover connect, disconnect mid-stream, permission denied and a
      false-route attempt.
- [ ] A manual run on the PM's glasses (checklist in `docs/release/glasses.md`) is done with the PM.
- [ ] `docs/release/glasses.md` sets out the full path to wider release, ready for when Meta
      opens distribution: Developer Center project, Universal Link + AASA, a Beta release channel,
      internal TestFlight and App Store GA.

## Out of scope
Ray-Ban Display UI, glasses voice invocation, public glasses distribution.

## Open product questions
None. Settled in DECISIONS #18–#19.

## Engineering decisions (filled in by the lead while building)
- …

## Risks / what could go wrong for users
- DAT is a developer preview, so firmware or Meta AI updates can break it. Mitigation: the phone
  path always works; the version matrix is pinned in the doc.
- Developer Mode can switch off after firmware updates. The doc tells the PM how to turn it back on.
