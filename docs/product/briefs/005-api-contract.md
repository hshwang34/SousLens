# Brief 005 — Slice 3 API contract (backend ⇄ iOS)

All under `/v1`, bearer auth, snake_case, ISO-8601 UTC, the standard error envelope. Owner-only
resources return identical 404s for foreign and missing ids. Additive to Slices 0–2.

## Food preferences (SUB-02)

| Method | Path | Body → Response |
|---|---|---|
| GET | `/me/preferences` | → Preferences |
| PUT | `/me/preferences` | Preferences → Preferences |

```jsonc
// Preferences
{"allergies": ["peanut", "shellfish"], "avoid": ["cilantro"], "updated_at": "iso|null",
 "unrecognized": ["dragon fruit"]}   // entries that map to no allergen class or dictionary food
```
Entries are short free text (≤ 60 chars, ≤ 30 each), normalised server-side against the ingredient
dictionary and its allergen flags (`"peanuts"` → `peanut`; `"tree nuts"` covers almond, walnut, …).
Allergies are hard blocks; "avoid" is a soft preference.

## Substitutions (SUB-01/02/05, PRD §8.4)

`POST /substitutions/suggest`
`{"recipe_version_id": "uuid", "ingredient_ref": "ing-3"}` → **200**

```jsonc
{
  "recipe_version_id": "uuid", "ingredient_ref": "ing-3", "target_ingredient": "mirin",
  "suggestions": [
    {"suggestion_id": "uuid",                     // stable for this response; send back on approve
     "source": "rule|ai",                         // rule = vetted seed table; ai = advisor (mock in Slice 3)
     "candidate": "rice vinegar + a pinch of sugar",
     "kind": "close_equivalent|flavor_adaptation|structural_substitution",
     "ratio_or_amount": "1 tbsp rice vinegar + 1/2 tsp sugar",
     "rationale": "...", "impact_flavor": "...", "impact_texture": "...",
     "adjusted_steps": [{"step_id": "step-2", "instruction": "..."}],
     "confidence": "high|medium|low",
     "risks": ["Slightly sharper; add the sugar."],
     "allergy_warning": "string|null",            // set when an ingredient overlaps a sensitivity class
     "requires_user_confirmation": true}
  ],
  "cannot_substitute": false,
  "reason": "string|null",                        // required when cannot_substitute or suggestions == []
  "safety_notice": "string|null"                  // e.g. the recipe itself contains one of your allergens
}
```

Rules (deterministic, `domains/safety` precedence: allergy > food-safety rule > creator warning >
pantry > preference > creativity):
- Seed rules first (`fixtures/substitution_rules.json`, vetted, covering the seeded recipes), then
  the `SubstitutionAdvisor` (mock in Slice 3) for anything else; at most 3 suggestions, rules first.
- A suggestion whose candidate contains a user allergy (via dictionary allergen flags) is **dropped**;
  if nothing remains → `cannot_substitute: true` with a reason. Never "safe for you" wording.
- "avoid" items are dropped too, but only as a preference (reason says so).
- `kind: "not_recommended"` is never returned as a suggestion; those cases produce
  `cannot_substitute: true` (e.g. leavening and preservation structure, raw-egg emulsions).
- If the target ingredient itself is one of the user's allergens, include a `safety_notice` and
  still offer allergy-free suggestions.
- `ingredient_ref` must exist in the version (422) and the version must be readable (404).

## Cooking sessions (COOK-01..08, PRD §8.6, §10.3, §11.1)

```jsonc
// Session
{
  "id": "uuid", "recipe_version_id": "uuid", "recipe_id": "uuid",
  "status": "created|active|paused|completed|abandoned",
  "step_index": 0, "steps_count": 7, "revision": 3,
  "recipe": RecipeDetail,                          // the PINNED version, exactly as published
  "adaptations": [
    {"id": "uuid", "ingredient_ref": "ing-3", "original": "mirin",
     "replacement": "rice vinegar + a pinch of sugar", "ratio_or_amount": "...",
     "source": "rule|ai", "label": "Common swap|AI suggested adaptation",
     "reason": "mirin unavailable", "approved_at": "iso",
     "allergy_warning": "string|null", "risks": ["..."],   // copied from the suggestion; null/[] free-form
     "conflicts_with_allergies": false}                     // re-checked on every read
  ],
  "steps": [                                       // the session's view of each step
    {"step_id": "step-2", "order": 1,
     "instruction": "adapted or original text", "original_instruction": "…",
     "adapted": true, "adaptation_ids": ["uuid"],
     "suggested_timer": {"label": "Simmer", "duration_seconds": 600} | null}
  ],
  "timers": [{"id": "uuid", "step_index": 3, "label": "Simmer",
              "target_at": "iso", "status": "running|done|cancelled"}],
  "notes": [{"id": "uuid", "text": "…", "created_at": "iso"}],
  "outcome": null | {"result": "cooked|partly|didnt_work", "saved_changes": true},
  "pantry_snapshot": [{"pantry_item_id": "uuid", "normalized_name": "gochujang"}],
  "started_at": "iso|null", "ended_at": "iso|null", "updated_at": "iso"
}
```

| Method | Path | Body → Response |
|---|---|---|
| POST | `/sessions` | `{"recipe_version_id", "adaptations": [{"ingredient_ref", "suggestion_id"} or {"ingredient_ref", "replacement", "ratio_or_amount", "source", "reason"}]}` → **201** Session (`status: created`, `revision: 0`) |
| GET | `/sessions?status=active` | → `{"items":[SessionSummary]}` (created/active/paused; newest first) for the resume banner |
| GET | `/sessions/{id}` | → Session (canonical; COOK-07) |
| POST | `/sessions/{id}/commands` | header `Idempotency-Key` (required), body §11.1 → Session |
| POST | `/sessions/{id}/ask` | `{"query", "grounded_revision"}` → AskResponse |
| POST | `/sessions/{id}/notes` | `{"text"}` → **201** note |
| DELETE | `/sessions/{id}` | → 204 (PRIV-02; events, messages, timers, notes cascade) |

`SessionSummary` = `{id, recipe_version_id, recipe_id, title, status, step_index, steps_count, updated_at}`.

Limits (security review, brief 005):
- **Open sessions:** at most 3 open (`created|active|paused`) sessions per user; a 4th `POST /sessions`
  → **409 `STATE_CONFLICT`** with `details.open_session_ids` (newest first) so the app can offer
  to resume or abandon one.
- **Session creation:** at most 30 new sessions per user per hour → **429 `RATE_LIMITED`**
  (counted in a durable ledger; deleting sessions does not refund it).

### Commands (§11.1)

```jsonc
{"command": "start|next|back|jump_to_step|pause|resume|complete|abandon|
              approve_adaptation|revert_adaptation|start_timer|cancel_timer",
 "expected_revision": 3, "user_confirmed": true,
 "client_source": "ios_button|ios_voice|ios_assistant",
 "step_index": 4,                                       // jump_to_step
 "adaptation": {...},                                   // approve_adaptation (same shape as in POST /sessions)
 "adaptation_id": "uuid",                               // revert_adaptation
 "timer": {"label": "Simmer", "duration_seconds": 600}, // start_timer (1 s – 24 h)
 "timer_id": "uuid",                                    // cancel_timer
 "outcome": {"result": "cooked|partly|didnt_work", "save_changes": true}}  // complete (optional)
```
- **200** Session with `revision + 1` for any state change; boundary no-ops (back at step 0, jump to
  current step) → 200 with revision unchanged and no event.
- Same `Idempotency-Key` again → identical 200, no second event; same key with a different body →
  409 `STATE_CONFLICT`.
- Stale `expected_revision` → **409 `STATE_CONFLICT`**, `details.session` = latest Session.
- `user_confirmed` not exactly `true` → **422 `CONFIRMATION_REQUIRED`**.
- Missing `Idempotency-Key` → 422; non-owner → 404. Illegal transition (e.g. `next` at the last step,
  anything on a completed session) → 409 `INVALID_TRANSITION` with the latest Session.
- Step changes go only through the Step Oracle. Adaptations and timers are allowed while `created`,
  `active` or `paused`; they never change `step_index`. Reverting restores the original step text.
- `start_timer` stores an absolute `target_at` = server now + duration (COOK-06). A timer whose
  `target_at` has passed is reported `done` on read. Timers never start without a user command.
- `complete` with `outcome.save_changes: true` saves the session's adaptations as the user's
  **private variation** for that recipe (replacing any previous one). No public fork (P1).

### Ask (COOK-03/04, PRD §8.5, Appendix A)

```jsonc
// AskResponse
{
  "message_id": "uuid",
  "answer_text": "The recipe says … My suggestion: …",
  "grounding": [{"type": "recipe_step|ingredient|creator_note|adaptation", "id": "step-3"}],
  "grounded_session_revision": 3,
  "stale": false,                         // true if the session revision moved since grounded_revision
  "uncertainty": "low|medium|high",
  "safety_notice": "string|null",
  "proposed_action": null | {"command": "next|back|jump_to_step|start_timer", "step_index": 4,
                              "timer": {...}},   // a PROPOSAL; the app must ask, then send a command
  "requires_confirmation": true|false
}
```
- The grounding packet (§8.5) uses only: the pinned version, current ± 1 steps, creator notes and
  warnings, approved adaptations, relevant pantry subset, last 10 turns, timers, preferences.
- Recipe text, notes and the user's query are untrusted data; the coach never changes state.
- Mock coach: answers from the current step's instruction, cues, warnings and creator notes; food
  safety questions ("is this chicken done?") always return a thermometer/verified-guidance notice
  and never certify doneness.
- `query` ≤ 500 chars. Ask limits: **120 asks per user per hour across all sessions** (durable ledger; new or deleted sessions never reset it) and 60 per session per hour → **429 `RATE_LIMITED`**.

## Private variation (COOK-08)

`GET /recipe-versions/{id}/my-variation` → `{"adaptations": [...], "saved_at": "iso", "recipe_version_id": "uuid"}`
or 404. Each `adaptations` element is exactly the Session adaptation shape
`{id, ingredient_ref, original, replacement, ratio_or_amount, source, label, reason, approved_at}`;
only swaps whose ingredient (same id and name) still exists in the requested version are returned.
`POST /sessions` accepts them back as `{ingredient_ref, replacement, ratio_or_amount, source, reason}`,
re-validated against the version and the caller's current allergies. `complete` with
`save_changes: true` but no active swaps leaves any existing variation untouched
(`saved_changes: false`).
`DELETE /recipe-versions/{id}/my-variation` → 204. The fit/start screen may offer "Use my changes
from last time", which sends those adaptations in `POST /sessions`.

## Version access (extends Slice 1)

`GET /recipe-versions/{id}` and fit/substitution calls are also allowed when the caller owns a
session pinning that version (the Slice 1 TODO).

## Notes (backend, brief 005)

- UUIDs are accepted in any case (iOS sends uppercase) in paths and bodies; responses use lowercase.
- `approve_adaptation` for an ingredient that already has an active swap replaces it (the old one is
  reverted in the same command). An allergy conflict or a not-recommended structural swap → 422.
- `cancel_timer` on an unknown timer → 404; on an already cancelled timer → 409 `INVALID_TRANSITION`.
  `revert_adaptation` on an unknown id → 404; already reverted → 409 `INVALID_TRANSITION`.
- `GET /sessions` without `status` lists all of the caller's sessions (newest first, max 50).

## Clarifications (fix round)

- **Preferences:** entries are parsed (split on commas / "and"; "allergic to", "no", "-free",
  "intolerant" stripped; "lactose intolerant" → `milk`, "gluten free" → `gluten`, "finfish" →
  `fish`). The response gains `unrecognized`: stored entries that map to neither an allergen class
  nor a dictionary food. They are still stored and matched word by word; the app should ask the
  user to check them.
- **Allergy matching is conservative:** "free-from" claims never clear an allergen ("gluten-free
  spaghetti" still conflicts with a wheat/gluten allergy), "may contain" counts as contains
  (tamari → wheat, chili crisp → peanut), bare "nuts" means tree nuts and peanut. Foods with no
  vetted record (sherry, pecorino, sriracha, …) get "We don't know what X contains" in
  `allergy_warning` for any user with allergies.
- **Doneness / safe-to-eat and raw-tasting questions** (DECISIONS #15) are answered from a fixed
  template and the model is not called: `answer_text` = "The recipe says (step N): <success cues>.
  My suggestion: <notice> I can't tell from a description or photo whether the food has cooked
  through."; `safety_notice` = the thermometer notice (USDA safe minimum internal temperatures),
  `uncertainty: "high"`, `proposed_action: null`. With a high-risk food in the step or recipe,
  "ready", "can I eat / serve it", "finished", "off the heat", "long enough", "medium rare" etc.
  all count.
- **`proposed_action` arguments** come only from the user's words (step number, duration) or the
  current step's `suggested_timer`, never from the model.
- **Session adaptations** carry `allergy_warning` and `risks` (copied from the suggestion on
  approve; `null`/`[]` for free-form) and `conflicts_with_allergies` (re-checked on every read;
  such swaps are never saved by `save_changes`). The same fields appear in `my-variation`.
- **Free-form adaptations** (`{ingredient_ref, replacement, …}`) are labelled `source: "rule"` /
  "Common swap" only when the replacement is a vetted seed suggestion for that ingredient;
  otherwise `source` is forced to `"ai"`. They go through the same blockers as suggestions
  (allergy, creator "do not substitute" warning or creator note, seed no-swap / never list,
  structural rules) → 422.
- **`POST /sessions/{id}/notes`** accepts an optional `Idempotency-Key`: a retry with the same key
  returns the same 201 note (no second row); the same key with a different text → 409
  `STATE_CONFLICT`. Without the header, behaviour is unchanged.
- **Limits:** `POST /substitutions/suggest` → 429 `RATE_LIMITED` after 60 advisor calls per user
  per hour (rule-only answers don't count); at most 200 live suggestions per user (older ones are
  dropped, so an old `suggestion_id` may 422). Commands → 429 after 600 per session per hour;
  `metadata` string values ≤ 200 chars.
- **Replay window:** only the last 50 command responses per session are kept for replay; replaying
  an older `Idempotency-Key` → 409 `STATE_CONFLICT` with `details.session` (latest).
- **409 `INVALID_TRANSITION`** for an already reverted adaptation or an already cancelled timer
  also carries `details.session`.
- **Seeded recipe v2:** the gochujang chicken fixture now reserves marinade before the raw chicken
  goes in (food-safety fix); the seed publishes it as version 2. Sessions pinned to v1 stay on v1.

