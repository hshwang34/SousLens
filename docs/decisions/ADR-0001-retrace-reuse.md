# ADR-0001 — Port from Retrace, don't fork it

**Date:** 2026-10-20 · **Status:** accepted

## Context

Retrace (`_retrace_ref/`, `~/Documents/Projects/Retrace`) is a hackathon-grade iOS app forked from
Meta's DAT `CameraAccess` sample plus a FastAPI server with SQLite, in-memory sessions, no auth, an
industrial design system, hand tracking, and a troubleshoot mode. The May scoping audit proposed
forking it wholesale. PRD §1.5 says "reuse concepts … but do not require a general-purpose workflow
platform", and PRD §9/§10 define a different data model (immutable recipe versions, pantry,
server-authoritative Step Oracle, Postgres, per-user ownership).

## Decision

Fresh repositories with the PRD §16.1 layout. Port specific, proven modules and patterns:

| Retrace module | SousLens use | Slice |
|---|---|---|
| `services/video_probe.py`, `clip_extractor.py` | `backend/app/media/` ffprobe validation + per-step clips, fault-tolerant per step | 5 |
| `services/gemini_processor.py` (Files API upload + structured output + timestamp clamping) | `backend/app/ai/extractor/gemini.py` behind `RecipeExtractor` | 5 |
| `services/ephemeral_token.py` | `POST /v1/ai/live-token` (P1 route, feature-gated) | 4/P1 |
| `services/prompt_builder.py` current-step-only prompt | Cooking Coach grounding packet (PRD §8.5) | 3–4 |
| `services/session.py` tool dispatcher shape | Step Oracle *proposal* parsing (never direct mutation) | 3 |
| iOS `BonjourDiscovery`, server-settings override | `ios/SousLens/Services/API` | 0 |
| iOS Gemini Live WebSocket client, `goAway` reconnect | Slice 4 `SpeechInput`/`AudioOutput` Live adapter | 4 |
| iOS DAT wiring (`Wearables.configure`, MockDeviceKit, preview/frame grab) | `MetaGlassesCameraSource` | 6 |
| Token-driven Asset Catalog, type scale, "tool not toy" rigor | `ios/SousLens/DesignSystem` with warmer tokens | 0–1 |
| TestFlight CI (Fastlane match + tag trigger) | Reproduce for `com.souslens.ios` when the PM asks | 7 |

Not ported: troubleshoot mode, hand tracking, HUD design system, PDF manual ingest, SQLite store,
in-memory sessions, global (unowned) procedures.

## Consequences

- More up-front scaffolding in Slice 0, but every table is owned, versioned and tested from day one.
- Retrace's Gemini Live wire-protocol handling is reused verbatim where it applies, which removes the
  riskiest part of Slice 4.
- The DAT SDK is added only in Slice 6, so Slices 0–5 build and test on any Mac without the SDK.
