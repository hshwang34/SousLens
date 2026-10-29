# 008 — Slice 5: creator video → recipe (Retrace capture)

**Status:** building (backend PR #11 merged; iOS next) · **Owner:** PM · **PR:** #11 · **Updated:** 2026-10-28

## Problem
Writing a recipe by hand takes a creator hours. The PRD's creator promise is "film yourself
cooking once, get a structured recipe with step clips".

## Who it's for
Creators uploading their own cooking video (CAP-01: MP4/MOV, ≤15 min, ≤200 MB).

## What success looks like
A creator uploads their own video, watches a progress state, then corrects an AI draft (with
every AI field labelled) and publishes. Cooks can then play two or more step clips from the
published recipe. A failure always leaves an editable draft.

## Acceptance criteria
- [ ] The upload goes through a signed Tigris URL, and the phone never holds a provider key. The
      app rejects bad type, duration or size with a clear message, and the user confirms that it
      is their own video.
- [ ] A background worker validates with ffprobe, extracts with Gemini (Files API, then delete)
      into the existing draft schema, and renders padded step clips with ffmpeg.
- [ ] The app polls job status and shows queued / processing / ready / failed. Malformed output
      gets one retry, then a partial editable draft. Quantities are never invented: unknown stays
      unknown.
- [ ] The review screen marks AI-extracted fields (`evidence_origin`). The creator can fix them,
      trim clips and publish an immutable version.
- [ ] Media rules: no base64 in the DB, the source video is kept until the creator deletes it
      (DECISIONS #20), clips are kept only for published versions, and the creator can
      delete their media.
- [ ] Video extraction respects the budget guard (off at the $15 soft limit, 5 per user).
- [ ] Recorded-fixture tests for the extractor. ffmpeg and ffprobe are tested on a tiny fixture
      clip in CI.

## Out of scope
External TikTok/YouTube links, auto-publishing, editing the video itself.

## Open product questions
1. **Keep the creator's source video after publish?** Options: A) delete after 7 days, B) keep
   forever. **Recommendation:** A. It costs less, and the PRD wants retention minimised.
   → *Answer:* **B, keep until the creator deletes it** (DECISIONS #20).

## Engineering decisions (filled in by the lead while building)
- …

## Risks / what could go wrong for users
- Timestamps are approximate. Mitigation: 1 s padding plus creator trim.
- Long processing times. Mitigation: the job runs async with honest progress and resumes after
  the app is relaunched.
