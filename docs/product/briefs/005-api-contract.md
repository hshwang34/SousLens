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
{"allergies": ["peanut", "shellfish"], "avoid": ["cilantro"], "updated_at": "iso|null"}
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
     "reason": "mirin unavailable", "approved_at": "iso"}
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
- `query` ≤ 500 chars; 60 asks per session per hour → 429.

## Private variation (COOK-08)

`GET /recipe-versions/{id}/my-variation` → `{"adaptations": [...], "saved_at": "iso"}` or 404.
`DELETE /recipe-versions/{id}/my-variation` → 204. The fit/start screen may offer "Use my changes
from last time", which sends those adaptations in `POST /sessions`.

## Version access (extends Slice 1)

`GET /recipe-versions/{id}` and fit/substitution calls are also allowed when the caller owns a
session pinning that version (the Slice 1 TODO).
