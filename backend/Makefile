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

db-up:
	docker compose up -d --wait

db-down:
	docker compose down

migrate:
	$(UV) run alembic upgrade head

seed: migrate
	$(UV) run python -m app.scripts.seed
