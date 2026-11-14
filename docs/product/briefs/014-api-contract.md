# Brief 014 — Voice recipe capture API contract (backend ⇄ iOS)

All under `/v1`, bearer auth, snake_case, ISO-8601 UTC, the standard error envelope. Additive:
no existing field changes meaning. Times inside a session are **`t_ms`: milliseconds since the
session started, on the phone's clock**. The server never reads the wall clock for asking,
spacing or expiry. **Audio is never sent or stored**, only transcript text.

Owner only: a session that belongs to someone else returns the same 404 as a missing one.
Every write except create needs an `Idempotency-Key` header (1–128 printable ASCII). The same
key with the same body replays the first response; the same key with a different body is
`STATE_CONFLICT` 409. On create the key is optional.

## Flow

```
POST /capture/sessions                       → session (status recording)
POST /capture/sessions/{id}/turns            every final caption batch / pause → {ask | null}
POST /capture/sessions/{id}/questions/{qid}  answered | skipped | later | expired
POST /capture/sessions/{id}/commands         stop_asking | pause | resume
POST /capture/sessions/{id}/finish           Done → ≤ 3 wrap-up questions (status wrapping_up)
POST /capture/sessions/{id}/questions/{qid}  answer / skip each wrap-up question
POST /capture/sessions/{id}/generate         → Job (kind capture), status generating
GET  /extractions/{job_id}                   poll until ready | failed (brief 008)
GET  /recipes/drafts/{draft_id}              review in the existing editor, then publish
GET  /capture/sessions/{id}                  resume after a relaunch (session + events)
```

## 1. Create — `POST /capture/sessions` → **201** (a replayed key → **200**)

```jsonc
{"mode": "voice", "title_hint": "Mum's Kimchi Jjigae"}   // title_hint optional, ≤ 120
```

`mode: "camera"` → `CAPTURE_MODE_UNAVAILABLE` 422 ("coming soon"). At most 3 sessions
`recording`/`wrapping_up` per user → `RATE_LIMITED` 429.

**Session**:

```jsonc
{
  "id": "uuid", "mode": "voice",
  "status": "recording|wrapping_up|generating|ready|failed",
  "title_hint": "…|null", "draft_id": "uuid|null", "extraction_job_id": "uuid|null",
  "asking_stopped": false, "paused": false, "live_asks_used": 0,
  "pending_question": null,          // the open live question (an Ask), if any
  "wrapup_questions": [],            // wrap-up questions not answered yet (Asks)
  "transcript_deleted": false,       // true once the draft was published or discarded
  "policy": {"silence_before_ask_ms": 1500, "min_ms_between_live_asks": 45000,
             "max_live_asks": 6, "question_ttl_ms": 20000, "max_wrapup_questions": 3},
  "started_at": "…", "ended_at": "…|null", "created_at": "…", "updated_at": "…",
  "events": null                     // only GET includes the events (below)
}
```

**Ask**: `{"question_id": "uuid", "text": "How long do you let it simmer?",
"topic_key": "simmer_time", "topic": "temperature|time|quantity|doneness|servings|prep|equipment",
"phase": "live|wrapup", "expires_at_ms": 81500}` (`expires_at_ms` is `null` for wrap-up).

## 2. Turns — `POST /capture/sessions/{id}/turns` → **200**

```jsonc
{
  "segments": [{"t_ms": 61000, "text": "now we let it simmer", "is_final": true}],  // ≤ 50
  "silence_ms": 1800,            // how long the creator has been quiet right now
  "assistant_speaking": false,   // Umma is talking: never ask
  "t_ms": 62800                  // optional "now"; defaults to the newest segment
}
→ {"ask": Ask | null, "stored": 1, "closed_question_id": "uuid|null", "asking_stopped": false}
```

* Only `is_final` segments are stored (≤ 2000 chars each); partials are captions only.
* Send a batch whenever captions finalise, and an empty batch with the current `silence_ms`
  when a pause starts (the phone's ~1.5 s gate). The server asks only when **all** hold:
  `silence_ms ≥ 1500`, `assistant_speaking` false, not paused, not "stop asking", no question
  open, `< 6` live questions so far, and `≥ 45 000` ms since the last question was asked or
  closed. The topic must be temperature, time, quantity or doneness, and never one already
  asked, answered or skipped.
* An open question whose `expires_at_ms` has passed is closed as `expired`
  (`closed_question_id`). A final segment that is just "skip" / "later" closes the open question
  the same way; "stop asking" turns live questions off for the session (`asking_stopped`).
* When an `ask` comes back: speak it, show the card, then report the outcome (§3).

## 3. Question outcome — `POST /capture/sessions/{id}/questions/{question_id}` → **200**

```jsonc
{"outcome": "answered|skipped|later|expired", "answer_text": "about fifteen minutes", "t_ms": 64000}
→ {"question_id": "uuid", "topic_key": "simmer_time", "outcome": "answered"}
```

`answer_text` is required for `answered` (her exact words; numbers are kept as said).
`later` defers a live question to the wrap-up; in the wrap-up `later` counts as `skipped`.
Unknown question → 404; already closed → `STATE_CONFLICT` 409.

## 4. Commands — `POST /capture/sessions/{id}/commands` → **200** Session

`{"command": "stop_asking|pause|resume", "t_ms": 90000}`. Pause stops questions (and the
phone stops captions); resume allows them again. Stop asking is for the rest of the session.

## 5. Finish — `POST /capture/sessions/{id}/finish` → **200**

Body optional: `{"t_ms": 1800000}`. Status → `wrapping_up`. An open live question is closed as
expired, the interviewer takes one last look at the whole transcript, and at most **3**
wrap-up questions come back: deferred ("later") ones first, then by importance
(temperature > time > quantity > doneness > servings > prep > equipment).
`→ {"questions": [Ask], "session": Session}`. Calling finish again returns the wrap-up questions
still open. Report each one through §3; anything left unanswered becomes "needs review".

## 6. Generate — `POST /capture/sessions/{id}/generate` → **202** Job

No body. Allowed in `wrapping_up` or `failed` (`recording` → 409 "Tap Done first"). Creates
the draft (`extracting`) and a Job (`kind: "capture"`, same shape as brief 008; `media_id`
null, no clips). Poll `GET /extractions/{job_id}`; on `ready` the session is `ready` and the
draft is in review, on `failed` the session is `failed` (generate may be called again) and
the draft is editable. Stages: `queued → extracting → done`.

Limits (the recording is always kept; nothing is lost):

* `CAPTURE_GENERATION_LIMIT` 429, `retryable: true`, `details: {limit, used}`: the per-user
  monthly AI draft allowance, shared with video extraction (5 per UTC month).
* `AI_RESTING` 503, `retryable: true`: the monthly AI budget is spent (Gemini only).
* `PROVIDER_NOT_CONFIGURED` 503.

Job failure codes: `AI_RESTING` (budget refused in the worker; doesn't use up the allowance),
`AI_SAFETY_BLOCKED`, `AI_OUTPUT_INVALID`, `PROVIDER_NOT_CONFIGURED`, `SESSION_DELETED`,
`TRANSCRIPT_EMPTY`, `JOB_FAILED`.

The draft follows brief 008 §4: every AI field has `evidence_origin: "ai_extracted"`,
quantities and times she never said stay `null` and are listed in `extraction.unknowns`, her
own phrases land in `creator_notes`. With `AI_PROVIDER=mock` the draft is built by simple
rules from her words (`extraction.demo: true`, with a notice saying so).

## 7. Get — `GET /capture/sessions/{id}` → **200** Session with events

```jsonc
"events": [
  {"id": "uuid", "t_ms": 61000, "kind": "utterance", "text": "now we let it simmer",
   "topic_key": null, "question_id": null},
  {"id": "uuid", "t_ms": 62800, "kind": "question", "text": "How long do you let it simmer?",
   "topic_key": "simmer_time", "question_id": null},
  {"id": "uuid", "t_ms": 64000, "kind": "answer", "text": "about fifteen minutes",
   "topic_key": "simmer_time", "question_id": "<the question's id>"}
]
```

Kinds: `utterance | question | answer | skip | marker` (`marker` text: `later`, `expired`,
`pause`, `resume`, `stop_asking`). Ordered by `t_ms`.

## 8. Delete — `DELETE /capture/sessions/{id}` → **204**

Deletes the session and its transcript. A draft already made from it is kept.

## Privacy

* No audio is accepted or stored; only transcript text and timings.
* The transcript events (and the interviewer's notes on them) are deleted when the draft made
  from the session is **published** or **deleted/discarded**, and when the session is deleted.
  After that `transcript_deleted` is `true` and `events` is empty.
