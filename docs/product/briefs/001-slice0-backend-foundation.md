# 001 — Slice 0: backend foundation

**Status:** approved · **Owner:** PM · **PR:** — · **Updated:** 2026-10-20

## Problem
Nothing exists yet. Every later slice (authoring, pantry, cooking engine) needs an owned, versioned,
tested data layer, dev sign-in, a seeded public recipe, and AI interfaces that work with no paid
inference. PRD §16 Slice 0.

## Who it's for
The demo operator / tester (PRD §2.3) and the lead: a backend that boots from the README, serves one
seeded recipe to a signed-in tester, and proves the architecture (Step Oracle, provider interfaces).

## What success looks like
- A tester can run `make db-up && make seed && make backend-dev` and open `/v1/recipes` to see the
  seeded Gochujang Chicken Thighs recipe with ingredients, steps, cues and creator attribution.
- A tester can sign in with an email (dev mode), get a token, and `/v1/me` shows them.
- Tests prove the Step Oracle state machine, auth isolation, and the error envelope.

## Acceptance criteria
- [ ] `GET /v1/health` → `{status:"ok", version, ai_provider:"mock"}`.
- [ ] `POST /v1/auth/dev-login {email}` only when `AUTH_MODE=dev`; creates the user on first use;
      returns a JWT; `GET /v1/me` returns display name + preference units. Non-dev mode → 404.
- [ ] Bearer verification dependency; missing/invalid token → 401 in the PRD error envelope
      `{error:{code,message,retryable,correlation_id}}`; every response carries `X-Correlation-Id`.
- [ ] All PRD §10 tables exist via SQLAlchemy models + one alembic migration: users, recipes,
      recipe_versions, recipe_media, recipe_drafts, extraction_jobs, saves, ingredients, pantry_items,
      pantry_observations, cooking_sessions, session_events, session_messages, timers,
      media_consents, feedback. UUID PKs, UTC timestamps, `owner_user_id` on owned resources.
- [ ] `GET /v1/recipes` (public, paginated by cursor, `query` filter on title) and
      `GET /v1/recipes/{id}` return the PRD §10.1 canonical recipe JSON shape (schema_version 1.0)
      for the latest published version, with creator attribution and immutable version id.
- [ ] `make seed` loads `fixtures/seeded_recipes/*.json` (at least Gochujang Chicken Thighs with
      ≥5 steps, one creator note, one warning, success cues) idempotently, owned by a seeded
      creator user.
- [ ] `app/domains/sessions/oracle.py`: pure state machine per PRD §8.6 (`created→active↔paused→
      completed|abandoned`; start/next/back/jump_to_step/pause/resume/complete/abandon; boundaries;
      `user_confirmed` required; revision increments) with unit tests for every transition and the
      idempotency/revision-conflict rules. No HTTP endpoint yet (Slice 3).
- [ ] `app/ai/providers/base.py`: typed Protocols `RecipeExtractor`, `PantryExtractor`,
      `SubstitutionAdvisor`, `CookingCoach`, `VisualObserver` with Pydantic request/response schemas
      taken from PRD §8.2–8.5, §10.2, §11.2, Appendix A. `MockAIProvider` returns fixture-driven,
      schema-valid outputs. `GeminiProvider` is a stub that raises `ProviderNotConfigured`.
      Selected by `AI_PROVIDER` env.
- [ ] `app/domains/safety/rules.py` skeleton with the precedence enum from PRD §8.4 and tests for
      the ordering (content rules come in Slice 3).
- [ ] Ownership helper: any owned resource fetched for a different user → 404 (no metadata leak).
      Integration test with two users.
- [ ] `backend/Makefile`: `check` (ruff check + ruff format --check + pytest), `dev`, `db-up`,
      `db-down`, `seed`, `migrate`. `uv` lockfile committed. Python 3.12.
- [ ] Structured JSON logs with request id; no request bodies logged.
- [ ] `make backend-check` passes locally and in `.github/workflows/backend.yml`.

## Out of scope
Drafts/publish endpoints (Slice 1), pantry/fit (2), sessions endpoints/substitutions (3), any real
Gemini call, media upload, Sign in with Apple, Supabase, deployment.

## Open product questions
None blocking — defaults from DECISIONS #4–#6 apply.

## Engineering decisions (filled in by the lead while building)
- Postgres everywhere (dev, tests, CI) via docker compose / GH service; no SQLite path, to keep
  JSONB/UUID behaviour identical. Tests create and migrate `souslens_test` per session.
- SQLAlchemy 2 async + asyncpg + alembic; Pydantic v2 schemas separate from ORM models.
- JWT HS256 (`pyjwt`) with `JWT_SECRET`; 30-day tokens for the pilot; `AuthProvider` interface so
  Apple can slot in (DECISIONS #5).
- Cursor pagination = opaque base64 of `(published_at, id)`.
- Fixture recipes are hand-authored JSON matching PRD §10.1; seed is upsert-by-slug.

## Risks / what could go wrong for users
- Dev login is intentionally weak; it must be impossible to enable outside `AUTH_MODE=dev`.
- If the canonical recipe JSON shape drifts later, iOS DTOs break — keep `schema_version`.
