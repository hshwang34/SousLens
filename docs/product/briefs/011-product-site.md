# 011 — Product website with TestFlight link

**Status:** in review (PR #9 merged; deploy pending) · **Owner:** PM · **PR:** #9 · **Updated:** 2026-10-28

## Problem
A TestFlight link alone tells nobody what SousLens is or why to install it.

## Who it's for
Prospective pilot testers and creators arriving from a shared link; also a portfolio viewer.

## What success looks like
In 10 seconds a visitor gets "record a recipe once; anyone can cook it with what they have",
trusts it (honest AI labels, safety, privacy), and taps "Join the TestFlight beta".

## Acceptance criteria
- [ ] Static site in `site/` (no build step), Mise brand (cream paper, herb green, tomato, serif
      display), light and dark, responsive to 320 px, Lighthouse a11y ≥ 95.
- [ ] Sections: hero + CTA, how it works (record → match pantry → cook with coaching), safety and
      honesty, privacy (on-device voice, photos not stored), creators, glasses ("in development",
      never claimed as available), FAQ, footer.
- [ ] A privacy policy page and a support page (needed by TestFlight/App Store Connect).
- [ ] The TestFlight URL lives in one config value. Until the link exists, the CTA reads "Beta
      opening soon" — never a dead link.
- [ ] Real app screenshots from the brand build (no mock device art claiming unreleased features).
- [ ] `/.well-known/apple-app-site-association` is reserved for the future glasses Universal Link.
- [ ] Deployed to Vercel `hshwang34` (preview first; production on PM go).

## Out of scope
Blog, waitlist backend, analytics, custom domain purchase (optional later — spends money).

## Open product questions
1. **Domain?** A) free `souslens.vercel.app` (if available), B) buy a domain (~$12/yr).
   **Recommendation:** A for the beta.
   → *Answer:* **A, free *.vercel.app** (DECISIONS #20).

## Engineering decisions (filled in by the lead while building)
- …

## Risks / what could go wrong for users
- Over-promising. Mitigation: every claim maps to a shipped feature; glasses marked "in development".
