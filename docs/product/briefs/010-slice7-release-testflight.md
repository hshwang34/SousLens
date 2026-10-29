# 010 — Slice 7: hardening + public TestFlight beta

**Status:** approved · **Owner:** PM · **PR:** — · **Updated:** 2026-10-28

## Problem
The app runs only on a laptop with dev sign-in. Nobody outside can try it.

## Who it's for
Pilot testers who tap a public TestFlight link, and Apple's Beta App Review.

## What success looks like
A stranger taps the link, installs, signs in with Apple, and gets through the PRD §15 demo
(phone-only) against the hosted backend. They can delete their account from Profile.

## Acceptance criteria
- [ ] **Sign in with Apple:** a nonce-bound identity token is verified server-side (Apple JWKS,
      aud/iss/exp/nonce), and `AUTH_MODE=apple` is used in production. Dev-login stays dev/test
      only. Existing tests are unchanged.
- [ ] **Account deletion** in Profile deletes the user's data and media and revokes the Apple
      token (`/auth/revoke`) (guideline 5.1.1(v)).
- [ ] **Review access:** a production-safe, single-account review login (secret code, rate
      limited, read/write only its own sandbox data) for Beta App Review. It is documented in the
      review notes.
- [ ] **Hosting:** a Fly app (web + worker process groups, ffmpeg in the image, alembic as the
      release command, health checks), Neon Postgres, Tigris bucket, secrets only in Fly. Runbook
      at `docs/release/backend.md`.
- [ ] **Hardening:** per-IP and per-user rate limits, the cost guard verified in production
      config, no raw photos or audio in logs, graceful permission-denied states, error-state UI pass.
- [ ] **iOS release config:** production API URL, server-URL override hidden outside debug,
      `ITSAppUsesNonExemptEncryption=NO`, privacy manifest + App Privacy answers drafted, build
      number from CI, and the archive exported headlessly with an App Store Connect API key.
- [ ] **Pipeline doc** `docs/release/testflight.md`: every human step (App ID + SIWA key, ASC app
      record, API key, privacy and test info, external group, public link), then a scripted
      `make release-ios`.
- [ ] Section 15 demo script passes end to end on a TestFlight build on a real iPhone.

## Out of scope
App Store submission, payments, Android, analytics SDKs.

## Open product questions
1. **Beta tester cap on the public link?** A) 100, B) 1,000, C) 10,000 (the Apple max).
   **Recommendation:** A. 100 keeps Gemini spend predictable within $25; it can be raised later.
   → *Answer:* **A, 100 testers** (DECISIONS #20).
2. **Support / privacy contact email shown to testers and Apple?** **Recommendation:**
   jacogoby@gmail.com (personal), or a new alias you create.
   → *Answer:* **jacogoby@gmail.com** (DECISIONS #20).

## Engineering decisions (filled in by the lead while building)
- …

## Risks / what could go wrong for users
- Beta App Review rejects the build. Mitigation: phone-only build, a review account, clear notes,
  and the AI features labelled.
- The Neon free tier sleeps, giving a slow first request. Mitigation: a health ping, and the
  $19 plan if it hurts.
