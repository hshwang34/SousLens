# SousLens backend. Run from this directory or via `make -C backend <target>`.
SHELL := /bin/bash
UV ?= uv
PORT ?= 8000

.PHONY: check lint test dev db-up db-down migrate seed

check: lint test

lint:
	$(UV) run --locked ruff check .
	$(UV) run --locked ruff format --check .

test:
	$(UV) run --locked pytest -q

dev:
	$(UV) run uvicorn app.main:app --reload --host 0.0.0.0 --port $(PORT)

env:  ## create backend/.env from .env.example with a freshly generated JWT secret
	@test -f .env && echo ".env already exists; delete it first to regenerate" && exit 1 || true
	@python3 -c "import secrets,pathlib; src=pathlib.Path('../.env.example').read_text(); pathlib.Path('.env').write_text(src.replace('JWT_SECRET=change-me-dev-only-32-bytes-minimum-please', 'JWT_SECRET='+secrets.token_hex(32)))"
	@echo "wrote backend/.env with a random JWT_SECRET"

db-up:
	docker compose up -d --wait

db-down:
	docker compose down

migrate:
	$(UV) run alembic upgrade head

seed: migrate
	$(UV) run python -m app.scripts.seed
