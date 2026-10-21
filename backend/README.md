# SousLens backend

FastAPI + SQLAlchemy 2 (async, asyncpg) + Postgres 16, managed with `uv` on Python 3.12.
`AI_PROVIDER=mock` is the default and needs no keys.

## Run

```bash
make env                       # .env from ../.env.example with a random JWT_SECRET; AUTH_MODE and
                               # JWT_SECRET are required (the app refuses to start without them)
make db-up                     # postgres:16 in docker, creates souslens + souslens_test
make seed                      # alembic upgrade head, then fixtures/seeded_recipes/*.json
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
