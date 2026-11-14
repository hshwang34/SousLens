# 015 — First-run onboarding, following creators, For You / Following feeds

**Status:** shipped · **Owner:** PM · **PR:** #20, #22, #24, #26, #28, #29, #35, #41, #42, #45, #46 · **Updated:** 2026-11-13

## Problem
A new user goes straight from sign-in to the tabs. Allergies are the strongest safety rule, but
they are only reachable through Profile → Preferences, so most new users cook with no allergy
data at all. Pantry fit (the whole "what can I make tonight" promise) stays empty until someone
finds the Pantry scan. And Umma is a recipe-sharing app with no way to follow the people whose
recipes you like.

## Who it's for
- **Learner / home cook** on their first launch: should leave onboarding with allergies set, a
  pantry (or a clear "later"), a few creators followed and a feed that already fits them.
- **Creator** on their first launch: same, plus a short path to recording their first recipe.
- **Demo operator** (PRD §2.3): predictable first run on seeded content.

## Storyboard
1. Sign in → **Welcome**: the tagline and three short value lines. "Get started".
2. **What brings you here?** "I want to cook" or "I want to share my family's recipes".
3. **Allergies.** Add allergies, or tap **No allergies**. One of the two is required.
4. **Your taste.** Diets (vegetarian, vegan, pescatarian, halal, kosher), favourite cuisines,
   and cooking skill (beginner, comfortable, confident). Skippable.
5. **Follow cooks you'll love.** Suggested creators, based on the cuisines chosen. Each card:
   avatar, name, one-line bio, two recipe titles, a Follow toggle. Nothing preselected. Skippable.
6. **What's in your kitchen?** "Scan my pantry", "Say what I have", or "Later".
7. **You're set.** Lands on Explore → **For You**. Creators also see "Record your first recipe".

## What success looks like
- A tester finishes onboarding in under 2 minutes without help, mock AI and all.
- After onboarding, For You shows "You have 8 of 9"-style reasons, and Following shows only the
  creators they followed.
- Nobody reaches the tabs without having answered the allergy question one way or the other.

## Acceptance criteria

**Gate**
- [ ] A signed-in user with no `onboarded_at` sees onboarding instead of the tabs, on every
      launch, until they finish it. Finishing sets `onboarded_at` on the server.
- [ ] A deep link opened during onboarding is applied after it finishes, not dropped.
- [ ] Back works on every step after Welcome. Progress is visible.

**Steps**
- [ ] Role saves immediately (`PATCH /me`). It is changeable later in Profile.
- [ ] Allergies reuse the Preferences rules: free text, normalised server-side, unrecognised
      entries shown as such. "No allergies" is an explicit choice. Locked safety wording
      (DECISIONS #15) is unchanged, and nothing says a recipe is "safe for you".
- [ ] Diets, cuisines and skill are closed lists. Diets are a soft preference (ranking only);
      medical diets stay out (PRD §4.3).
- [ ] Follow suggestions are up to 8 creators. Follow/unfollow is immediate and reversible.
- [ ] Pantry scan uses the existing capture sheet. Camera permission is asked only when the user
      taps to use the camera. "Later" shows a pantry nudge card on Explore until the pantry has
      an item.
- [ ] The creator path's "Record your first recipe" opens the brief 014 entry if shipped,
      otherwise the existing editor.

**Following**
- [ ] Tapping a creator's name on a card or recipe detail opens a creator profile: avatar, name,
      bio, recipe and follower counts, Follow button, their published recipes.
- [ ] Profile → **Following** lists followed creators; swipe to unfollow.
- [ ] A user cannot follow themselves.

**Feeds**
- [ ] Explore has two tabs: **For You** and **Following**. Search keeps using today's search.
- [ ] For You ranks by pantry fit (DECISIONS #22), boosted by favourite cuisines and followed
      creators, lowered for diet mismatches. Each card shows its reason.
- [ ] A recipe that conflicts with a stated allergy is moved to the bottom and labelled
      ("Contains peanut"). It is never hidden silently and never labelled safe.
- [ ] Following shows followed creators' recipes, newest first, with an empty state that links
      to suggestions.

**Seed content**
- [ ] Six **fictional** creator personas with original bios, avatars and 3–4 original recipes
      each, across Korean, Italian, Mexican, Indian, Japanese and weeknight basics.

## Out of scope
- Contact matching, address-book access, and finding people by email or phone.
- Following non-creators, followers lists, likes, comments, notifications (PRD §4.3 stays P2).
- Choosing a voice in onboarding.
- ML ranking or personalisation models.
- Real creators, names or brands of any kind.

## Open product questions
1. **Social graph now or after P0?** → *Answer:* now, follows + Following feed only (DECISIONS #27).
2. **How do people find each other?** → *Answer:* suggested creators + creator profiles. No
   contacts, email or phone.
3. **Preferences beyond allergies/avoid?** → *Answer:* diets, cuisines, skill. Units stay in
   Profile.
4. **Where else can you follow?** → *Answer:* creator profile page, plus a Following list.
5. **For You ranking?** → *Answer:* pantry fit + cuisines (+ followed creators), deterministic.

## PR sequence
1. docs: this brief, `015-api-contract.md`, DECISIONS #27.
2. backend: schema (migration 0010, models).
3. backend: preferences (diets/cuisines/skill), `PATCH /me`, onboarding complete.
4. backend: follows, creator profile, suggested creators.
5. backend: For You and Following feeds.
6. backend: seed creator personas and recipes; regenerate expected outputs.
7. iOS: models, services, fakes; shared chip/flow layout.
8. iOS: onboarding gate + steps 1–4 (behind `feature.onboarding`).
9. iOS: onboarding steps 5–7; flag on.
10. iOS: Explore For You / Following + pantry nudge.
11. iOS: creator profile, Following list, Preferences additions.

## Engineering decisions (filled in by the lead while building)
- Existing users are not backfilled: pilot testers see onboarding once.
- Seeded creators are users with `auth_provider = "seed"`, which no sign-in path accepts.
- For You computes fit per recipe per request. Fine for ~20 recipes; cap or cache before the
  catalogue grows.
- For You `coverage` counts required ingredients *present* in the pantry, ignoring amounts:
  scanned pantries rarely record quantities. `can_make` stays the strict fit verdict.
- Creator suggestions rank by how many of a creator's recipes are in the chosen cuisines, so a
  specialist beats a generalist with one matching dish.
- `DELETE /creators/{id}/follow` answers 404 for a non-creator unless the caller held a follow,
  so it never reveals an arbitrary user's name (found by automated security review).
- Creator pages open from the "by …" line on recipe detail, not from feed cards (a card is one
  tap target). Seeded personas have no avatar image; the app draws monograms.
- "Record your first recipe" opens Profile's new-recipe editor until brief 014's recorder ships.
- `feature.onboarding` (UserDefaults) defaults on; `-feature.onboarding NO` turns it off. The
  live smoke tests run with it off except `testOnboardingFirstRun`.

## Risks / what could go wrong for users
- Someone skips allergies by tapping "No allergies" to get through faster. Mitigation: plain
  copy saying allergies are used to warn them, and the Preferences entry stays in Profile.
- A thin Following feed if they follow nobody: empty state links back to suggestions.
- Seeded personas could be read as real people: profile bios say they are sample creators.
