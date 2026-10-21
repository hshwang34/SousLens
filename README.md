# SousLens

> Record a recipe once. Teach anyone to cook it, using the ingredients they actually have.

A creator publishes a structured, versioned recipe (optionally extracted from their own cooking
video). A learner checks their pantry by voice or photo, accepts transparent substitutions, and
cooks with a stateful assistant on iPhone — or through Meta AI glasses camera/audio when available.

- Product spec: [`PRD.md`](PRD.md) · how we build: [`docs/product/README.md`](docs/product/README.md)
- Engineering rules and invariants: [`CLAUDE.md`](CLAUDE.md)

## Run it

```bash
make env                           # backend/.env with a generated secret; mock AI needs nothing else
make db-up && make seed            # postgres 16 in docker + demo recipes
make backend-dev                   # http://localhost:8000/v1/health
make ios-project && open ios/SousLens.xcodeproj   # run on an iPhone simulator
make check                         # backend ruff+pytest, iOS build+test
```

Status: Slice 0 (foundation) in progress. See `docs/implementation-plan.md`.
