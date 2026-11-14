# 011 — Product website with TestFlight link

**Status:** shipped — live at https://ummacooks.app · **Owner:** PM · **PR:** #9 · **Updated:** 2026-11-13

## Problem
A TestFlight link alone tells nobody what Umma is or why to install it.

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
- [x] Deployed to Vercel `hshwang34` (project `umma-site`), live at https://ummacooks.app.

## Out of scope
Blog, waitlist backend, analytics, custom domain purchase (optional later — spends money).

## Open product questions
1. **Domain?** A) free `umma.vercel.app` (if available), B) buy a domain (~$12/yr).
   **Recommendation:** A for the beta.
   → *Answer:* **A, free *.vercel.app** (DECISIONS #20). Superseded: `umma.vercel.app` was taken,
   so the PM bought `ummacooks.app` (DECISIONS #26).

## Engineering decisions (filled in by the lead while building)
- Hosting: Vercel project `umma-site` (team `hyunseok-hwang-s-projects`), Git-connected to this
  repo with root directory `site/` and no build step. Production branch `main`.
- Ignored build step `git diff --quiet HEAD^ HEAD -- .`: only commits that touch `site/` deploy.
  **A merge to `main` that changes `site/` is a production deploy.** PRs get protected previews.
- `www.ummacooks.app` 308-redirects to `ummacooks.app`. `umma-site-gray.vercel.app` stays as the
  fallback URL.

## Risks / what could go wrong for users
- Over-promising. Mitigation: every claim maps to a shipped feature; glasses marked "in development".
