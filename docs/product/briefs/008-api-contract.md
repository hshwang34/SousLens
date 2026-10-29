# Brief 008 — Slice 5 API contract (backend ⇄ iOS)

All under `/v1`, bearer auth unless noted, snake_case, ISO-8601 UTC, the standard error envelope.
Additive to Slices 0–4: no existing field changes meaning, and hand-authored / seeded recipes
serialise byte-identically (the new fields below are **omitted**, not `null`, when unset).

## Flow

```
POST /media/upload-intents  → PUT bytes to upload_url (the phone talks to storage directly)
POST /media/{media_id}/uploaded  → job (202) + draft_id
GET  /extractions/{job_id}  every ~2 s until status is ready | failed
GET  /recipes/drafts/{draft_id}  → review: AI fields carry evidence_origin = "ai_extracted"
PATCH / trim / POST /recipes/drafts/{id}/publish  → as Slice 1, plus clips
GET  /media/{clip_id}  → short-lived signed URL to play a clip
```

## 1. Upload intent — `POST /media/upload-intents` → **201**

| Field | Type | Rules |
|---|---|---|
| `content_type` | string | `video/mp4` or `video/quicktime` |
| `size_bytes` | int | 1 … 209 715 200 (200 MB) |
| `duration_ms` | int? | ≤ 900 000 (15 min) when known; the worker re-checks with ffprobe |
| `owns_rights` | bool | must be `true` (the creator confirms it is their own video) |

```jsonc
{
  "media_id": "uuid",
  "upload_url": "https://…",            // presigned PUT, expires in 15 min
  "method": "PUT",
  "headers": {"Content-Type": "video/mp4", "Content-Length": "123456"}, // send EXACTLY these
  "expires_at": "…", "max_bytes": 209715200, "max_duration_ms": 900000
}
```

Content-Type and Content-Length are part of the signature: a different type or size is rejected
by storage. Errors: `RIGHTS_CONFIRMATION_REQUIRED` 422, `VIDEO_TYPE_UNSUPPORTED` 415,
`VIDEO_TOO_LARGE` 413, `VIDEO_TOO_LONG` 422, `VIDEO_EXTRACTION_LIMIT` 429
(`details: {limit, used}`; 5 per user per UTC month), `VIDEO_EXTRACTION_DISABLED` 503 (monthly
soft budget reached; matches `GET /ai/status → video_extraction_enabled: false`),
`PROVIDER_NOT_CONFIGURED` 503. Show `error.message` as is; every one leaves "write it by hand".

## 2. Mark uploaded — `POST /media/{media_id}/uploaded` → **202** (new) / **200** (repeat)

Optional body `{"title_hint": "…"}` (≤ 120 chars). Creates the draft (immediately readable,
not editable until the job ends) and one extraction job; calling again returns the same job.
Errors: `UPLOAD_INCOMPLETE` 409 (object missing, or size/type differs: re-upload), the limit
errors above, `STORAGE_UNAVAILABLE` 503 (retryable). Response: a **Job** (below).

## 3. Job — `GET /extractions/{job_id}` → **200**

```jsonc
{
  "id": "uuid", "kind": "extract|trim",
  "status": "queued|processing|ready|failed",
  "stage": "queued|downloading|validating|extracting|rendering_clips|done",
  "progress": 0,                    // 0–100, monotonic within an attempt
  "draft_id": "uuid",               // always present: the (partial) draft to open
  "media_id": "uuid|null",          // source video
  "clip_id": "uuid|null",           // trim jobs: the clip being rendered
  "demo": false,                    // true = AI-off demo content (see 4)
  "partial": false,                 // AI answer was partly unreadable; review every field
  "clips_ready": 3, "clips_failed": 0,
  "error": null,                    // failed: {"code", "message"}
  "attempts": 1, "created_at": "…", "updated_at": "…", "finished_at": "…|null"
}
```

Failure codes (the draft is back to editable in every case): `VIDEO_UNREADABLE`,
`VIDEO_TYPE_UNSUPPORTED`, `VIDEO_TOO_LONG`, `VIDEO_EXTRACTION_DISABLED`, `AI_SAFETY_BLOCKED`,
`AI_OUTPUT_INVALID`, `PROVIDER_NOT_CONFIGURED`, `SOURCE_DELETED`, `JOB_FAILED` (gave up after
retries); trim only: `CLIP_RENDER_FAILED`, `CLIP_SUPERSEDED`. A clip failure never fails an
extraction (`clips_failed` > 0, the step simply has no clip). Jobs resume after a worker or app
restart; just keep polling.

## 4. Draft additions (`GET/PATCH /recipes/drafts/{id}`, list summaries)

- `extraction` (omitted on hand-authored drafts; read-only, ignored if echoed in PATCH):
  ```jsonc
  {"job_id": "uuid", "source_media_id": "uuid|null", "demo": false, "partial": false,
   "unknowns": ["amount of sesame oil not stated"],  // also the failure message, first
   "notice": null}   // demo: "Demo extraction: AI is off, so this sample recipe was not read…"
  ```
- `ingredients[].evidence_origin`: `"ai_extracted" | "creator_reviewed" | "creator_authored"`,
  **omitted** when not set (all pre-Slice-5 data). Accepted on PATCH like `steps[].evidence_origin`.
  Set it to `creator_reviewed` when the creator edits/confirms an AI field.
- AI quantities are `null` (with `unit: null`) unless shown or spoken in the video: render as
  unresolved. AI steps carry `source_start_ms` / `source_end_ms` (padded ±1 s, clamped to the
  video) and `source_clip_id` (a media id) when a clip was rendered.
- While the job is `queued|processing`, PATCH / publish / trim → 409 `STATE_CONFLICT`
  (`details.job_id`).

## 5. Trim — `POST /recipes/drafts/{draft_id}/steps/{step_id}/trim` → **202** Job

Body `{"start_ms": int, "end_ms": int}` within the source video, 0.5 s – 10 min long. The step
points at the new (pending) `clip_id` straight away, with the new span; the previous clip is
deleted if it was never published. Poll the returned job. Errors: 404 (draft/step), 409 (draft
published or extracting, or the source video was deleted), 422 (range).

## 6. Publish (unchanged endpoint) — what's new

- `ai_extracted` ingredients/steps are published as `creator_reviewed` ("AI-extracted,
  creator-verified").
- A step whose clip is still rendering or failed → 422 with a `steps[i].source_clip_id` problem.
- Clips used by the published steps are attached to the version and kept; the draft's other
  clips are deleted. The source video is kept until the creator deletes it (DECISIONS #20).
- `GET /recipes/{id}` exposes `steps[].source_clip_id`; no URLs are embedded (they expire).

## 7. Media — reads, list, delete

`GET /media/{media_id}` (auth optional) → **200**
```jsonc
{"id": "uuid", "kind": "source_video|step_clip", "status": "pending|ready|failed|rejected",
 "mime_type": "video/mp4", "size_bytes": 1, "duration_ms": 1, "start_ms": 0, "end_ms": 0,
 "draft_id": "uuid|null", "recipe_id": "uuid|null", "step_id": "step-1|null",
 "published": true, "url": "https://…|null", "url_expires_at": "…|null", "created_at": "…"}
```
The owner can read all their media; anyone can read a **published step clip of a non-private
recipe** (cooks). Everything else is 404. `url` is a signed GET valid for 1 h; fetch it again
when it expires. `GET /media?kind=source_video|step_clip` lists the caller's media (no URLs).

`DELETE /media/{media_id}` → **204**. Source video: always allowed except while its job is
running (409). Unpublished clip: allowed. Published clip: 409 (kept with its version). Objects are
removed from storage shortly after (outbox drained by the worker).

## Ownership

Another creator's media, job, or draft is the same 404 as a missing one, on every endpoint above.
