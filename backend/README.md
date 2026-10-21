# SousLens backend

FastAPI + SQLAlchemy 2 (async, asyncpg) + Postgres 16, managed with `uv` on Python 3.12.
`AI_PROVIDER=mock` is the default and needs no keys.

## Run

```bash
cp ../.env.example .env        # defaults work for the compose DB (host port 5433)
make db-up                     # postgres:16 in docker, creates souslens + souslens_test
make seed                      # alembic upgrade head, then fixtures/seeded_recipes/*.json
make dev                       # http://localhost:8000/v1/health  (docs at /docs)
curl -s localhost:8000/v1/recipes | python3 -m json.tool
```

Dev sign-in (only when `AUTH_MODE=dev`):

```bash
curl -s -X POST localhost:8000/v1/auth/dev-login \
  -H 'content-type: application/json' -d '{"email":"tester@example.com"}'
# → {"access_token": "...", "token_type": "bearer", "user": {...}}; use it as `Authorization: Bearer`.
```

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
app/domains     users, recipes (public read side), ownership, sessions/oracle (Step Oracle), safety
app/ai          provider Protocols + schemas, MockAIProvider, Gemini stub, registry
app/api/v1      health, auth, me, recipes
app/scripts     seed
tests           unit/ (pure), integration/ (httpx + real Postgres)
```

Migrations: edit models, then `uv run alembic revision --autogenerate -m "..."` and review the
file (deferred `use_alter` foreign keys must be added by hand, see `0001_initial_schema.py`).
