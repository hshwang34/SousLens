# Brief 007 — Slice 4 API contract (backend ⇄ iOS)

All under `/v1`, bearer auth, snake_case, ISO-8601 UTC, the standard error envelope. Additive to
Slices 0–3: no existing field changes meaning, and under `AI_PROVIDER=mock` every existing
response is byte-identical to Slice 3 (the new `ai_notice` field is **omitted**, not `null`).

## The "AI is resting" flag (`ai_notice`)

Present only when the answer came from the labelled demo (mock) path because a Gemini budget cap
was reached. Absent on live answers and in mock mode. Clients must treat a missing key as "no
notice".

```jsonc
"ai_notice": {
  "code": "AI_RESTING",
  "message": "AI is resting — demo answers for now",   // show this text as is
  "reason": "user_daily_cap|monthly_cap",               // $0.25/user/UTC day; $22 UTC month
  "demo": true
}
```

It can appear on:

| Endpoint | Demo behaviour when it appears |
|---|---|
| `POST /sessions/{id}/ask` | Deterministic recipe-grounded answer (same as mock mode). |
| `POST /sessions/{id}/inspect` | Mock observation (no pixels analysed); still labelled and filtered. |
| `POST /pantry/observations` (photo) | `candidates: []`, `provider: "mock"`, a note asking to type or say items. A real photo is never answered with made-up items. |
| `POST /pantry/observations` (transcript) | Deterministic transcript parser; `provider: "mock"`. |
| `POST /substitutions/suggest` | Vetted rules plus the mock advisor table. |

## AI status (banner)

`GET /ai/status` → **200**

```jsonc
{
  "provider": "gemini|mock",
  "live": true,                       // false when a cap is reached (or mock mode)
  "video_extraction_enabled": true,   // false after the $15 monthly soft-degrade (Slice 5 reads it)
  "ai_notice": { ... }                // same shape as above; omitted when live or in mock mode
}
```

`live` turns false once less than about one interactive call ($0.05) of headroom is left, so the
banner can show before the next answer falls back. Mock mode returns
`{"provider": "mock", "live": false, "video_extraction_enabled": true}`.

## Look: visual inspect (PRD §11.2)

`POST /sessions/{id}/inspect` — `multipart/form-data`, one user-initiated photo for the current step.

| Part | Type | Rules |
|---|---|---|
| `image` | file | JPEG, PNG or HEIC (magic bytes checked), ≤ 5 MB. Required. |
| `query` | text | 1–500 chars, same text rules as `/ask`. Required. |
| `grounded_revision` | text (int) | The session revision the client was showing. Optional. |
| `captured_at` | text | ISO-8601, ≤ 64 chars. Optional, informational. |

→ **200**

```jsonc
{
  "observation_id": "uuid",                     // the stored assistant turn (text only)
  "observation": "The cucumber pieces appear uneven; a few look larger than bite-sized.",
  "step_alignment": "The step asks for bite-sized pieces.",
  "confidence": "low|medium|high",              // qualitative bin, not calibrated
  "limitations": ["...", "One photo can't show everything in the pan, and it can't confirm doneness or food safety."],
  "suggested_action": "string|null",
  "food_safety_certified": false,               // always false
  "grounded_revision": 7,
  "recommended_step_change": null,              // always null: a photo never moves a step
  "stale": false,                               // true → show "Based on previous step"; never change the step
  "label": "Visual estimate — not verified",    // show verbatim (PRD §13.4)
  "evidence_origin": "ai_observation",
  "safety_notice": "string|null",               // thermometer / verified-guidance notice when relevant
  "grounding": [{"type": "recipe_step", "id": "step-3"}],
  "ai_notice": { ... }                          // only on the demo fallback
}
```

Rules the server enforces (the client never needs to):

- The photo is processed in memory for the one call and dropped. It is never written to disk,
  the database or a log. Only the question and the text observation are kept, as session turns
  (the observation prefixed "(AI observation)"), so a follow-up `/ask` has the context.
- DECISIONS #15: a doneness / safe-to-eat / temperature / raw-tasting question is answered from
  the fixed template (no model call): `confidence: "low"`, `observation` "I can't tell from a
  description or photo whether the food has cooked through.", the thermometer notice in
  `safety_notice`. Any model sentence that could certify doneness or safety is removed; if that
  happens `confidence` drops to `"low"` and `safety_notice` is set. For recipes with poultry,
  pork, ground meat, fish or eggs `safety_notice` is always set.
- Limits: 20 photos per user per hour (429 `RATE_LIMITED`), plus the Gemini budget.

Errors: 404 (foreign or missing session), 409 `INVALID_TRANSITION` (session completed or
abandoned), 413 (> 5 MB), 415 (not an image / not multipart), 422 `VALIDATION_ERROR`
(missing `image` or `query`), plus the AI errors below.

## AI errors (all AI endpoints, live path)

| Status | `code` | `retryable` | Meaning / client action |
|---|---|---|---|
| 422 | `AI_SAFETY_BLOCKED` | false | Gemini's safety filter blocked the request or answer. Show the message; keep the step as written. Never retried. |
| 502 | `AI_OUTPUT_INVALID` | true | Malformed output twice (one retry already done). Offer retry; the step is unchanged. |
| 503 | `PROVIDER_UNAVAILABLE` | true | Timeout (about 20 s), repeated 429/5xx, or a rejected request. Show the current step; offer retry. |
| 503 | `PROVIDER_NOT_CONFIGURED` | false | Server misconfiguration (no key). |

A pantry photo whose output is partly malformed after the retry returns the candidates that did
validate plus the note "Some items couldn't be read. Check the list and add anything missing by
hand." (an editable partial result, still requiring confirmation).

## Voice

Voice is Apple on-device (DECISIONS #19): the app sends the confirmed, editable transcript to
`/ask` as `query`, exactly like typed text. There is no audio endpoint.
