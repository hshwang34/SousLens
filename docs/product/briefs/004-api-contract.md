# Brief 004 — Slice 2 API contract (backend ⇄ iOS)

All under `/v1`, bearer auth, snake_case JSON, ISO-8601 UTC, the standard error envelope. Every
pantry resource is owner-only (foreign or missing id → identical 404). Additive to Slices 0–1.

## Pantry items (PAN-01, PAN-05)

```jsonc
// PantryItem
{
  "id": "uuid",
  "raw_label": "Gochujang",              // what the user said / typed / the model read
  "normalized_name": "gochujang",        // matching key (see Matching)
  "ingredient_id": "uuid|null",          // dictionary entry when recognised
  "quantity": 2.0, "unit": "count",      // both nullable; unit from the Units list or null
  "quantity_is_estimate": false,         // true only when it came from a photo count
  "storage_location": "fridge|freezer|pantry|counter|other|null",
  "note": "string|null",
  "source": "manual|voice|photo",
  "confidence": 0.91,                    // null for manual
  "last_confirmed_at": "iso", "created_at": "iso", "updated_at": "iso"
}
```

| Method | Path | Body → Response |
|---|---|---|
| GET | `/pantry` | → `{"items":[PantryItem]}` sorted by `normalized_name` |
| POST | `/pantry` | `{"items":[NewItem], "observation_id":"uuid|null"}` → **201** `{"items":[PantryItem]}` |
| PATCH | `/pantry/{id}` | any of `raw_label, quantity, unit, storage_location, note` → PantryItem (`last_confirmed_at` = now) |
| POST | `/pantry/{id}/confirm` | `{}` → PantryItem with `last_confirmed_at` = now ("still have it") |
| DELETE | `/pantry/{id}` | → 204 |

`NewItem` = `{raw_label, quantity?, unit?, storage_location?, note?, source, confidence?,
quantity_is_estimate?, resolution?}` where `resolution` is `null | {"merge_into": "<pantry item id>"}
| {"keep_both": true}`.

**Duplicates are never resolved silently (PAN-04).** If a NewItem normalises to the same name as an
existing pantry item and has no `resolution`, the whole request is rejected with **409
`DUPLICATE_PANTRY_ITEM`** and `details.conflicts: [{"index": 0, "existing": PantryItem}]`. The client
asks the user per conflict and resends with `resolution`. `merge_into` updates the existing item
(new quantity/unit only if provided, `last_confirmed_at` = now, `source` of the new item). Distinct
allergen identities and raw/cooked states never normalise together.

## Observations — candidates only, nothing persisted to the pantry (PAN-02, PAN-03)

| Method | Path | Body → Response |
|---|---|---|
| POST | `/pantry/observations` | transcript: JSON `{"mode":"transcript","transcript":"..."}`; photo: `multipart/form-data` with `mode=photo`, `image` (JPEG/PNG/HEIC, ≤ 5 MB, magic bytes checked) → **201 Observation** |

```jsonc
// Observation (PRD §10.2)
{
  "observation_id": "uuid",
  "mode": "transcript|photo",
  "provider": "mock|gemini",             // UI must show "Demo mode — not a real detection" for mock photos
  "candidates": [
    {"raw_label": "Gochujang", "canonical_name": "gochujang", "quantity": null, "unit": null,
     "quantity_is_estimate": false, "confidence": 0.91, "confidence_bin": "high|medium|unknown",
     "evidence": "package label", "action": "add|ignore",
     "duplicate_of": "pantry item uuid|null"}          // server pre-flags likely duplicates
  ],
  "unknowns": ["contents of the unlabeled jar"],
  "requires_confirmation": true,
  "expires_at": "iso"                                   // observation row TTL (24 h), no image kept
}
```

- Confidence bins (PRD §8.3, UX bins, not calibrated): `high` > 0.85, `medium` 0.6–0.85,
  `unknown` < 0.6 (`action: "ignore"` by default, `canonical_name` may be null).
- Quantities only when explicitly spoken or visibly countable (`quantity_is_estimate: true` for
  photo counts). Never infer expiry, freshness or safety.
- The image is processed in memory and never written to disk or the database; only candidate JSON
  is stored on the observation row, which expires after 24 h (PRIV-01).
- **Mock mode:** transcripts go through a deterministic parser (commas, "and", number words, units).
  Photos return a fixture: the multipart field `fixture=<stem>` selects
  `fixtures/expected_outputs/pantry_observations/<stem>.json` (honoured only when
  `AI_PROVIDER=mock`); otherwise the `demo_counter` fixture is returned. `provider` is always
  `"mock"` so the app can label it honestly (PRD Appendix C).
- Rate limit: 30 observations per user per hour → 429 `RATE_LIMITED`.

## Recipe fit (FIT-01..03, PRD §12)

`POST /recipe-versions/{version_id}/fit` (`{}` body; same access rule as `GET /recipe-versions/{id}`)
→

```jsonc
{
  "recipe_version_id": "uuid",
  "can_make": false,                     // true only if every required item is "available"
  "coverage": 0.75,                      // required satisfied / required total; for sorting only
  "counts": {"available": 6, "uncertain": 2, "missing": 1, "optional_missing": 1},
  "items": [
    {"ingredient_ref": "ing-3", "name": "eggs", "optional": false,
     "status": "available|uncertain|missing|optional_missing",
     "reason": "You have 1 egg; the recipe needs 3.",
     "required": {"quantity": 3, "unit": "count"},
     "pantry_item_id": "uuid|null", "pantry_quantity": {"quantity": 1, "unit": "count"},
     "conversion_note": "string|null"}
  ],
  "computed_at": "iso"
}
```

Status rules (PRD §12.1): `available` = matched and quantity sufficient (after a supported
conversion) or the recipe item has no quantity; `uncertain` = matched but pantry quantity unknown,
insufficient-but-unknown units, mass↔volume needed, item confirmed more than **14 days** ago, or an
ambiguous alias; `missing` = no compatible item; `optional_missing` = optional and absent. Reasons
are human-readable sentences.

## Matching and units

- Normalisation: trim, casefold, collapse whitespace, singularise (dictionary-driven, e.g.
  tomatoes→tomato, but not "molasses"), then alias lookup in the `ingredients` dictionary
  (`fixtures/ingredients.json`, seeded by `make seed`): `scallion = green onion = spring onion`.
- Qualifiers that change identity are preserved and must match: fresh/dried, raw/cooked,
  sweetened/unsweetened, ground/whole. `gochujang ≠ gochugaru`.
- Units: count; mass g, kg, oz, lb; volume ml, l, tsp, tbsp, cup, fl_oz. Convert within a family
  only. No mass↔volume conversion → `uncertain` with a `conversion_note`.
