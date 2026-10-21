# Implementation plan — P0 requirement → slice → files → tests

Per PRD §16.2. Slices follow PRD §16; briefs in `docs/product/briefs/`. Paths are the intended
homes; writers may add files but should not move these without updating this table.

| Req | Slice | Backend | iOS | Tests |
|---|---|---|---|---|
| AUTH-01 | 0 | `app/core/security.py`, `app/api/v1/auth.py`, `app/domains/users` | `Services/Auth`, `Features/Profile/SignInView` | `tests/integration/test_auth.py` (isolation, 401/403), `SousLensTests/AuthTests` |
| REC-01 | 0/1 | `app/api/v1/recipes.py` (list/detail), seed script | `Features/Explore`, `Features/Recipe/RecipeDetailView` | `test_recipes_public.py`, DTO decode tests |
| REC-02 | 1 | `recipes.py` search; `saves` table + `/save` | Explore search, Saved tab | idempotent save test |
| REC-03 | 1 | `app/domains/recipes/drafts.py`, `/recipes/drafts` | `Features/Creator/{DraftEditor,IngredientEditor,StepEditor}` | draft CRUD + validation tests |
| REC-04 | 1 | `drafts.py#publish` → immutable `recipe_versions` | Publish button + version badge | publish v1 → edit → v2; v1 untouched |
| REC-05 | 1 | attribution in DTOs; unpublish keeps versions | creator label on detail | unpublish hides from feed, version still readable by session |
| REC-06 | 1 | edit published → new draft | "Edit" creates draft | no in-place mutation test |
| CAP-01..04 | 5 | `app/media/upload.py`, `app/workers/extraction.py`, `app/ai/extractor` | `Features/Creator/ImportVideoView` | ffprobe reject, job states, clip gen, failure → editable draft |
| PAN-01 | 2 | `app/api/v1/pantry.py`, `app/domains/pantry` | `Features/Pantry/PantryListView` | CRUD + ownership |
| PAN-02 | 2 | `/pantry/observations` mode=transcript → `PantryExtractor` (mock: deterministic parser) | mic push-to-talk → transcript → review | 15 transcript fixtures |
| PAN-03 | 2 | `/pantry/observations` mode=photo → `PantryExtractor` (mock: fixture lookup) | `PhoneCameraSource` photo → review | blurry image → uncertain |
| PAN-04 | 2 | `POST /pantry` with selected candidates only | `ScanReviewView` | reject leaves pantry unchanged |
| PAN-05 | 2 | `pantry_items.source/confidence/last_confirmed_at` | provenance badges | schema test |
| FIT-01..03 | 2 | `app/domains/matching` (normalize, aliases, qualifiers) + `/recipes/{version_id}/fit` | `Features/Recipe/PantryFitView` | scallion=green onion; gochujang≠gochugaru; 1 egg vs 3 eggs → uncertain |
| SUB-01..05 | 3 | `app/domains/substitutions` (seed rules + `SubstitutionAdvisor`), `app/domains/safety` | `PantryFitView` swap sheet, revert | allergen block, no-match → `cannot_substitute` |
| COOK-01 | 3 | `POST /sessions` pins version/subs/pantry snapshot | `Features/Cooking/CookingView` start | pin survives recipe v2 publish |
| COOK-02 | 3 | `app/domains/sessions/oracle.py` + `/sessions/{id}/commands` | Next/Back/Jump UI | idempotency, 409 conflict, 422 unconfirmed, boundaries |
| COOK-03 | 3 (mock) / 4 (real) | `app/ai/coach` grounding packet + `/sessions/{id}/ask` | `AssistantDrawer` with source badges | grounding refs present; stale revision labeled |
| COOK-04 | 3 (typed) / 4 (voice) | `/ask` text | typed query box; push-to-talk in 4 | typed path works with AI off |
| COOK-05 | 4 | `/sessions/{id}/inspect` + `VisualObserver` | Look button | uncertainty contract, no doneness certification |
| COOK-06 | 3 | `timers` table, timer commands | clip player, read-aloud (AVSpeechSynthesizer), timers | timer `target_at` survives restart |
| COOK-07 | 3 | `GET /sessions/{id}` canonical | `SessionStore` resume on launch | kill/relaunch restores step/overlay/timers |
| COOK-08 | 3 | complete/abandon + `/notes` | `SessionEndView` | outcome stored |
| WEA-01..05 | 6 | — | `Services/Glasses` DAT adapter, `MetaGlassesCameraSource`, route check | MockDeviceKit + disconnect tests |
| PRIV-01 | 2/5 | consent records, transient image delete | permission explainers, capture indicator | no retention test |
| PRIV-02 | 2/3 | DELETE pantry/sessions/drafts | delete flows | cascade tests |
| SEC-01 | 0 | ownership deps on every router | — | cross-user 404 tests |
| SEC-02 | 5 | MIME/size/duration enforcement, signed URLs | — | reject non-media |

## Slice gates (PRD §16)

- **0** simulator opens the seeded recipe from the API; backend + iOS tests run in `make check`.
- **1** publish v1, edit → v2, v1 references unchanged.
- **2** spoken multi-item input and one image each produce reviewable candidates; no silent writes.
- **3** complete one recipe with an accepted substitution, relaunch recovery, idempotent step changes.
- **4–7** see PRD; not started without a PM go (DECISIONS #3).
