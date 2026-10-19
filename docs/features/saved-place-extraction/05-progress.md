# Saved-place extraction progress

## Summary

Planning dossier drafted for a compliant, local-first URL/video-to-confirmed-place flow. The first
functional milestone is explicit: derive a place name and location from permitted URL metadata or
temporary on-device video evidence, then require confirmation. No feature code, dependency, service,
or credential has been added.

## Attention needed

- Persona review is deferred at the owner's request while core functionality is finalized.
- A human must approve the consolidated dossier before implementation.
- Build kickoff must separately approve the Django package set and Railway commands, place provider,
  billing, credentials, public-client abuse protection, attribution/retention policy, and evaluation
  dataset.
- Dark-mode PR #3 integration order must be decided before touching shared Saved/Map UI.

## Documents

- [Research](00-research.md)
- [Brief](01-brief.md)
- [Brief review history](01-brief_reviews.md)
- [Architecture](02-architecture.md)
- [Potential scaffolding](03-scaffolding.md)
- [Implementation plan and verification](04-plan.md)
- [Progress](05-progress.md)

## Phase status

| Phase | Status | Evidence |
|---|---|---|
| Platform/API research | Complete | [00-research.md](00-research.md) |
| Brief | Draft complete | [01-brief.md](01-brief.md) |
| Architecture | Draft complete | [02-architecture.md](02-architecture.md) |
| Scaffolding | Draft complete | [03-scaffolding.md](03-scaffolding.md) |
| Plan and verification | Draft complete | [04-plan.md](04-plan.md) |
| Persona review | Deferred by owner | Existing findings retained in [history](01-brief_reviews.md) |
| Consolidated human approval | Approved for core milestone | User approved the fixture-backed URL/video-to-confirmed-place build on 2026-10-19 |
| Implementation | Not started | Core build authorized; no feature code written yet |

## Decisions

| Decision | Status |
|---|---|
| Personal confirmed saves, not public/community density | Selected |
| Explicit share/paste only | Selected |
| TikTok official oEmbed metadata | Selected |
| Instagram share text, typed text, screenshot, or user-provided video; URL remains local | Selected |
| URL-first intake with optional user-provided video fallback | Selected |
| Video frame OCR and supported audio transcription run on-device | Selected |
| Video is temporary, never uploaded, and deleted after evidence extraction | Selected |
| Build compliant core with an unused scraper-provider seam; no Apify dependency or calls | Selected |
| Mandatory candidate confirmation | Selected |
| Local-first SwiftData | Selected |
| Discrete emerald cells/circles; no gradient | Selected |
| Django modular monolith + PostgreSQL on Railway | Selected |
| Supabase excluded from this feature | Selected |
| PostHog Cloud candidate; no analytics SDK in this feature | Selected |
| Place provider evaluated/approved at build kickoff | Pending human decision |
| Public community map | Deferred to a separate future brief |

## Task and evidence log

| Task | Status | Evidence/next action |
|---|---|---|
| Preserve existing scaffold reconnaissance | Complete | Existing files and gaps recorded in architecture |
| Record official API/provider findings | Complete | Research document with official citations |
| Define requirements and non-goals | Complete | SPE-1 through SPE-20 |
| Define states, contracts, trust boundaries, and alternatives | Complete | Architecture document |
| Define potential iOS/backend structure | Complete | Scaffolding document |
| Define coherent slices and single verification table | Complete | Plan document |
| Run persona reviews | Complete (round 1) | Sofia 6, Marcus 3, Grace 5, Amara 4, Andre 5 |
| Resolve focused blocking findings | Complete | SPE-14 through SPE-17 and planner boundary added |
| Resolve scope-expansion findings | Owner decision recorded | Keep focused; separate future briefs |
| Select backend structure | Complete | Django modular monolith with PostgreSQL on Railway; Supabase deferred |
| Run persona reviews on amended dossier | Deferred | Owner requested focus on core functionality; prior findings and dispositions preserved |
| Define core video-to-place milestone | Complete | URL-first flow plus temporary on-device video evidence produces confirmed name/location |
| Obtain consolidated human approval | Complete for core milestone | Fixture-backed core build approved; live provider/API remains a separate gate |

## Approval record

On 2026-10-19, the owner approved `approve_core_build` with no required changes. This authorizes
implementation of URL intake, optional temporary user-provided video processing, on-device
OCR/transcription, fixture-backed place-name/location candidates, explicit confirmation, and local
persistence.

The approval does not authorize a paid place API, cloud media upload, social-media downloading,
production credentials, or public rollout. Persona review remains deferred at the owner's request
and does not block the approved core milestone.
