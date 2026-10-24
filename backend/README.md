# SousLens backend

FastAPI + SQLAlchemy 2 (async, asyncpg) + Postgres 16, managed with `uv` on Python 3.12.
`AI_PROVIDER=mock` is the default and needs no keys.

## Run

```bash
make env                       # .env from ../.env.example with a random JWT_SECRET; AUTH_MODE and
                               # JWT_SECRET are required (the app refuses to start without them)
make db-up                     # postgres:16 in docker, creates souslens + souslens_test
make seed                      # alembic upgrade head, then fixtures/ingredients.json (upsert)
                               # and fixtures/seeded_recipes/*.json
make dev                       # http://localhost:8000/v1/health  (docs at /docs)
curl -s localhost:8000/v1/recipes | python3 -m json.tool
```

Dev sign-in (only when `AUTH_MODE=dev`; DECISIONS #5) is a two-step proof of possession: the
one-time code is printed to the **server log**, never returned by the API.

```bash
# 1. ask for a code (202). Watch the `make dev` terminal for a JSON line like
#    {"logger":"souslens.devlogin","message":"dev sign-in code","email":"tester@example.com","code":"483920",...}
curl -s -X POST localhost:8000/v1/auth/dev-login \
  -H 'content-type: application/json' -d '{"email":"tester@example.com"}'
# → {"challenge_id":"<uuid>","expires_in_seconds":600,"hint":"Check the server log for your sign-in code."}

# 2. exchange challenge id + code for a token (200)
curl -s -X POST localhost:8000/v1/auth/dev-login/verify \
  -H 'content-type: application/json' -d '{"challenge_id":"<uuid>","code":"483920"}'
# → {"access_token":"...","token_type":"bearer","user":{...}}; use it as `Authorization: Bearer`.
```

Codes expire after 10 minutes, are single use, allow 5 attempts, and at most 5 open challenges
per email (a sixth invalidates the oldest). Wrong, expired, reused or unknown → `401
UNAUTHORIZED` "Invalid or expired sign-in code". Tests set `DEV_LOGIN_ECHO_CODE=true`
(allowed only when `ENVIRONMENT=test`) so the 202 body also carries `code`.

## API (`/v1`)

Bearer auth unless marked public; errors use the PRD §11 envelope. Full shapes:
`docs/product/briefs/003-api-contract.md` (recipes), `004-api-contract.md` (pantry, fit) and
`005-api-contract.md` (preferences, substitutions, sessions).

| Method | Path | Notes |
|---|---|---|
| GET | `/health` | public |
| POST | `/auth/dev-login`, `/auth/dev-login/verify` | dev mode only (two-step, code in the server log) |
| GET | `/me` | current user |
| GET | `/me/saved` | saved recipes, newest save first |
| GET | `/me/recipes` | my published recipes (any visibility) + `has_open_draft` |
| GET | `/recipes?query=&tag=&cursor=&limit=` | public feed; `query` matches title or any ingredient; `saved` is `null` when anonymous |
| GET | `/recipes/{id}` | latest version; 404 unless public or mine; `share_url` |
| POST/DELETE | `/recipes/{id}/save` | idempotent |
| POST | `/recipes/{id}/edit` | owner: new draft from the latest version (409 `details.draft_id` if one is open) |
| POST | `/recipes/{id}/unpublish` | owner: visibility → private; versions untouched |
| GET | `/recipe-versions/{version_id}` | exact version; only if public, mine, saved by me, or pinned by one of my sessions |
| POST/GET | `/recipes/drafts` | create / list mine |
| GET/PATCH/DELETE | `/recipes/drafts/{id}` | owner; PATCH merges top-level fields, arrays replace whole; published → 409 |
| POST | `/recipes/drafts/{id}/publish` | 201 `PublishResult`; 422 with `details.problems` |
| GET | `/pantry` | my confirmed pantry, sorted by `normalized_name` |
| POST | `/pantry` | 201; selected items only (+ `observation_id` provenance); 409 `DUPLICATE_PANTRY_ITEM` with `details.conflicts` unless each duplicate has `resolution` (`merge_into` / `keep_both`) |
| PATCH | `/pantry/{id}` | owner; `null` clears a field (not `raw_label`); setting `quantity` clears `quantity_is_estimate`; reconfirms |
| POST | `/pantry/{id}/confirm` | owner; "still have it" → `last_confirmed_at` = now |
| DELETE | `/pantry/{id}` | owner; 204 |
| POST | `/pantry/observations` | 201 candidates only (24 h TTL, never pantry truth). JSON transcript, or multipart photo (`image` JPEG/PNG/HEIC ≤ 5,000,000 bytes, magic-byte checked → 415/413; processed in memory, never stored). Mock: `fixture=<stem>`, default `demo_counter`. 30/user/hour → 429 |
| POST | `/recipe-versions/{version_id}/fit` | available / uncertain / missing / optional_missing per ingredient with reasons; same access rule as `GET /recipe-versions/{id}` |
| GET/PUT | `/me/preferences` | allergies (hard blocks) + avoid (soft), normalised: `peanuts`→`peanut`, `tree nuts`, `dairy`→`milk`, ≤ 30 × 60 chars |
| POST | `/substitutions/suggest` | vetted rules (`../fixtures/substitution_rules.json`) first, then the advisor; one swap policy (`domains/substitutions/policy.py`) for suggest, session create, approve and variation replay; ≤ 3 suggestions stored 24 h (≤ 200 per user); 60 advisor calls/user/hour → 429 |
| POST | `/sessions` | 201; pins version, adaptations, step 0, relevant pantry snapshot. ≤ 3 open per user (409 `details.open_session_ids`), 30 new/user/hour (429) |
| GET | `/sessions?status=active`, `/sessions/{id}` | resume banner / canonical session (steps overlay, timers done-on-read, notes, outcome) |
| POST | `/sessions/{id}/commands` | `Idempotency-Key` required; Step Oracle; replay → identical 200; key reuse with another body or stale revision → 409 `STATE_CONFLICT` (`details.session`); unconfirmed → 422 `CONFIRMATION_REQUIRED`; illegal → 409 `INVALID_TRANSITION`; 600/session/hour; replay kept for the last 50 events |
| POST | `/sessions/{id}/ask` | grounded coach answer (§8.5 packet), `stale`, proposals only (arguments from the user's words); doneness / raw-tasting questions get a fixed template without calling the model; 120/user/hour + 60/session/hour → 429 |
| POST | `/sessions/{id}/notes` | 201 private note; optional `Idempotency-Key` (retry → same note, other text → 409) |
| DELETE | `/sessions/{id}` | 204; events, messages, timers, notes, adaptations cascade |
| GET/DELETE | `/recipe-versions/{version_id}/my-variation` | private saved swaps (Session adaptation shape) / 204 |

`recipe_versions` is append-only: a `BEFORE UPDATE OR DELETE` trigger (migration 0002) raises on
every row. Operator repairs need `SET LOCAL souslens.unlock_versions = 'on'` in the same
transaction; the app never sets it.

## Check

```bash
make check                     # ruff check + ruff format --check + pytest
```

Integration tests use `TEST_DATABASE_URL` (default: the compose `souslens_test` DB), run the
alembic migration at session start and truncate every table between tests.

## Layout

```
app/core        config (env + .env), errors (PRD envelope), security (JWT, AuthProvider), logging
app/db          models for every PRD §10 table, async engine, alembic migrations
app/domains     users, recipes (public read side, drafts/publish), ownership, sessions/oracle, safety,
                matching (dictionary, normalise, units, fit), pantry (CRUD, observations, upload),
                substitutions (rules, adapt, suggest), sessions (service, ask, intent), usage (limits)
app/ai          provider Protocols + schemas, MockAIProvider, Gemini stub, registry
app/api/v1      health, auth, me (+ preferences), recipes (+ fit, my-variation), pantry,
                substitutions, sessions
app/scripts     seed
tests           unit/ (pure), integration/ (httpx + real Postgres)
```

Migrations: edit models, then `uv run alembic revision --autogenerate -m "..."` and review the
file (deferred `use_alter` foreign keys must be added by hand, see `0001_initial_schema.py`).

## Pantry and matching notes (brief 004)

- The ingredient dictionary lives in `../fixtures/ingredients.json` and is upserted into
  `ingredients` by `make seed`; the API reads it from the DB per request. An alias claimed by two
  entries fails the seed (and `tests/unit/test_matching_normalize.py`).
- Pantry photos never touch disk: the request body is read into memory and parsed with
  `python_multipart` callbacks (`app/domains/pantry/upload.py`), because Starlette's
  `request.form()` spools files over 1 MB to a temp file. The test
  `test_image_bytes_are_never_written_to_disk_or_db` guards it.
- `uv run pytest tests/unit/test_pantry_transcripts_eval.py -s` prints transcript-parser
  precision/recall over `../fixtures/pantry_transcripts.json`.

## Seeded recipe versions (brief 005)

Published versions are immutable, so a fixture edit becomes a new version.
`../fixtures/seeded_recipes/history/<slug>/v<N>.json` holds the earlier contents; `make seed`
publishes any missing version in order with deterministic ids, so a fresh database and one that
only had v1 end up identical. The gochujang chicken marinade fix (reserve marinade before the raw
chicken goes in) is v2; `../fixtures/expected_outputs/*.json` reflect v2.

