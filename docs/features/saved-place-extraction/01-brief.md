# Saved-place extraction and personal density map brief

## Problem, user, and context

Plandit's core user already has restaurants and activities saved across TikTok and Instagram, but
those links do not become structured places that can be mapped, compared, or turned into a day.
The current iOS scaffold accepts shared links but assigns random sample places and loses everything
on relaunch.

This feature turns a social URL or user-provided video into a confirmed place name and location.
URLs remain the lowest-friction first attempt. When permitted metadata is insufficient, the user can
provide the video, a screenshot, or typed clues without Plandit downloading social media. Confirmed
saves can later create a personal density layer that shows where the student's own interests
cluster. The layer is not a public trending map or a feed for unrelated places.

## Product premise

Plandit remains a planner, not a discovery feed:

- Input: places the user explicitly shares or pastes.
- Transformation: extract clues, resolve candidate places, and ask the user to confirm.
- Output: a trustworthy personal map and structured saves that can later feed budget-, time-, and
  distance-aware planning.

Doing nothing leaves the app's central promise dependent on mock data. Building a public community
heatmap first would require accounts, aggregation consent, moderation, abuse controls, and a new
discovery-oriented product thesis before the personal save flow is proven.

## Solution outline

1. The user shares or pastes a TikTok or Instagram Reel URL; alternatively, they share or select a
   video file they are authorized to provide.
2. Plandit validates and canonicalizes the URL and immediately creates a local saved-source record.
3. Plandit first uses permitted URL/share metadata. If that evidence is insufficient, it offers
   typed text, a screenshot, or a video file processed temporarily on-device.
4. On-device Vision OCR samples video frames and on-device Speech recognition transcribes audio
   when supported. The user can review the resulting evidence; the media is not retained.
5. A contract-first Django service on Railway turns approved evidence into place-search queries and
   returns ranked candidates from an approved place-provider adapter.
6. The user confirms, changes, or manually searches for the correct place name and location.
7. The confirmed result shows its saved age, source, address, distance/travel estimate from the
   user's chosen location, known availability/cost context, and an immediate Add to Today action.
8. The confirmed save persists locally with its source URL and provider place ID.
9. The Saved map shows pins at close zoom and discrete emerald density zones at wider zoom levels.
   Density is based only on confirmed saves in the user's local library.

## Requirements

| ID | Requirement |
|---|---|
| SPE-1 | Accept a supported TikTok or Instagram URL from the share extension or paste flow and deduplicate exact canonical source URLs. |
| SPE-2 | Validate and canonicalize URLs without scraping pages or following unsafe redirects. |
| SPE-3 | For TikTok, use documented oEmbed metadata as extraction evidence and preserve normal source attribution. |
| SPE-4 | For Instagram, retain the URL as a source reference and use only text explicitly supplied through the share operation. When that is insufficient, ask for typed/pasted text, a screenshot, or a user-provided video; do not scrape Instagram pages or use Instagram oEmbed metadata as extraction input. |
| SPE-5 | Run screenshot and user-provided video evidence extraction on-device. Sample video frames for Vision OCR and transcribe audio on-device when supported; show the extracted evidence for correction/removal before place matching and provide typed/manual fallback when recognition is unavailable. |
| SPE-6 | Return up to three ranked place candidates with name, category, neighborhood/address, and confidence/evidence; always provide manual search. |
| SPE-7 | Do not create a mapped save until the user explicitly confirms a place. |
| SPE-8 | Persist source, extraction state, confirmation state, provider place ID, and allowed place fields locally so saves survive relaunch. |
| SPE-9 | Show individual saved-place pins at close zoom and discrete emerald density zones at wider zoom, calculated only from confirmed personal saves. |
| SPE-10 | Tapping a density zone frames or filters the confirmed saves represented by that zone rather than opening unrelated recommendations. |
| SPE-11 | Failed, unavailable, ambiguous, or deleted-source states remain understandable and recoverable without losing user-entered evidence. |
| SPE-12 | Never download arbitrary social video/audio, crawl feeds, call undocumented platform endpoints, or expose provider credentials in the app. |
| SPE-13 | Provide deterministic fixtures and a labeled evaluation set that measures URL handling, candidate quality, confirmation, persistence, and density output. |
| SPE-14 | Keep the normal TikTok share-to-confirmation path below 30 seconds median and two minutes p95, and the normal Instagram screenshot/text-to-confirmation path below two minutes p95, excluding time the user leaves the app; manual place research is a fallback, not the expected happy path. |
| SPE-15 | After confirmation, show saved age, original source access, full address, distance or travel-time estimate with its selected origin and mode, reliable open/closed/hours or event-expiry context, cost context, and Add to Today. When trustworthy monetary data exists, show an amount or range and its basis, such as per person, admission, or typical item; price symbols alone do not satisfy the requirement. Label unavailable data as unknown rather than implying a complete cost or current availability. |
| SPE-16 | Let the user view density for all confirmed saves, the last 30 days, or the last 7 days; show the active time window so old saves do not look current. |
| SPE-17 | Keep link intake, evidence correction, candidate confirmation, manual place search/save, the personal map, and local saved data available without a trial or paywall; when an external service is disabled, unavailable, or over quota, explain the limitation and retain a manual completion path. |
| SPE-18 | Display when operational status, hours, event expiry, and monetary context were last checked. Refresh fields that exceed the approved provider-specific stale threshold before presenting them as current; if refresh fails, retain place identity but show the affected fields as unknown or stale. |
| SPE-19 | Treat user-provided video as temporary evidence: validate type/size/duration, process it outside the share extension, avoid permanent media storage, delete staged copies after evidence extraction or cancellation, and never upload the media in this MVP. |
| SPE-20 | Optimize the first functional milestone for one outcome: from a supported URL or user-provided video, return up to three candidate place names and locations, allow manual correction, and persist a user-confirmed place. Density and enriched cost/availability presentation must not block proving this core path. |

## User-visible states

| State | Meaning | Next action |
|---|---|---|
| Queued | Link was accepted locally | Wait or leave the app |
| Reading link | Documented metadata is being requested | Wait |
| Needs details | URL metadata was insufficient | Add text, screenshot, or video |
| Reading video | User-provided media is being processed on-device | Wait or cancel |
| Finding places | Corrected text is being matched | Wait |
| Confirm place | One to three candidates need a decision | Confirm, search, or reject |
| Saved | Confirmed place is persisted and mapped | Add to a plan |
| Could not map | No reliable candidate or source unavailable | Retry, add details, or keep as an unmapped reference |

## Density behavior

- Count confirmed save records, not public post volume or unique community users.
- Exact duplicate source URLs count once.
- Different posts that the user confirms to the same place increase that location's personal save
  count; the close-zoom pin may show the count.
- Default to the last 30 days for a current personal-interest view, with visible 7 days, 30 days,
  and All controls.
- Wider zoom levels aggregate confirmed coordinates into stable map cells.
- Use three or four discrete size/opacity levels in emerald; no gradient.
- Never imply "popular now," live foot traffic, safety, quality, or community trend.

## Scope

### Included

- Explicit share/paste ingestion.
- TikTok oEmbed metadata.
- Instagram share text plus typed-text, screenshot/OCR, or user-provided-video fallback.
- User-provided video frame OCR and on-device audio transcription with temporary-media cleanup.
- Contract-first Django extraction and place-provider API backed by PostgreSQL.
- Mandatory place confirmation and manual correction.
- SwiftData local-first persistence.
- Personal confirmed-save pins and discrete density zones.
- Recent-save density windows and visible save age.
- Confirmed-place details with source, travel/distance, availability/cost context, and Add to Today.
- Visible provider-data freshness, stale refresh, and unknown fallback behavior.
- Deterministic fixtures, provider fakes, and an evaluation dataset.

### Deferred

- Public or friends-based community density.
- TikTok/Instagram account connection and saved-post import.
- Background feed crawling or creator/profile imports.
- Cloud media OCR/transcription.
- Cross-device sync and accounts.
- Recommendation feeds, sponsored placement, or public popularity rankings.
- Automatic day-plan optimization, which consumes confirmed saves in a later feature.
- A no-saves recommendation/discovery path. Plandit's product thesis starts with places the student
  already wants to visit; onboarding and plan generation are separate product surfaces.
- Browser-based group plan sharing, meeting-point selection, and collaborative budgeting. Confirmed
  saves are valid inputs to that separate planning/sharing feature, but extraction does not own it.

### Prohibited

- Instagram/TikTok page scraping, headless browsing, undocumented APIs, or downloader services.
- Downloading raw social video/audio from shared URLs.
- Retaining or uploading a user-provided video after local evidence extraction.
- Pinning a low-confidence match without confirmation.
- Sending user screenshots to a cloud processor without a separately approved consent/retention
  design.

## Success and quality gates

- 100% of mapped saves have explicit user confirmation.
- 100% of unsupported/unsafe URLs fail without a backend fetch to the destination.
- Candidate evaluation target: at least 90% top-three recall on the approved labeled dataset before
  replacing the scaffold.
- TikTok confirmation completes below 30 seconds median and two minutes p95; Instagram evidence to
  confirmation completes below two minutes p95 in representative usability runs.
- The core fixture/live evaluation records whether the correct place name and location appear in the
  top three before density or enrichment work is considered.
- Density output is deterministic for the same confirmed-save coordinates and zoom/cell version.
- A saved place remains available after termination/relaunch with no network connection.
- Price symbols alone never satisfy known-cost acceptance; reliable amounts/ranges include their
  basis, and unavailable amounts are visibly unknown.
- Operational and monetary fields never appear current without a visible last-checked time and
  provider-approved freshness decision.
- No raw screenshot leaves the device in the MVP.
- Basic intake, confirmation, manual completion, and personal-map behavior has no trial/paywall.

## Analytics and logging

No analytics library is added in this feature. If product analytics exists at build time, only
coarse funnel events may be considered: link accepted, details requested, candidate shown,
confirmed, manually searched, rejected, and failed. Events must not include source URLs, captions,
OCR text, screenshots, exact coordinates, tokens, or provider payloads.

Operational logs use request IDs, provider name, state transition, latency bucket, and normalized
error code. Sensitive evidence remains excluded.

## Planner and group-sharing boundary

This feature must hand a confirmed place—including known cost/availability fields and explicit
unknowns—to the existing Today flow immediately. It must not claim that one place's price level is a
complete day total, transit fare, or step-by-step route.

Budget-aware day totals, dietary constraints, exact transit instructions, meeting points, and a
browser-viewable plan for friends are important planning requirements, but they are not safely
folded into extraction/density. They require separate briefs and acceptance tests. Public launch
messaging for this feature must describe organizing and mapping the user's own saves, not claim that
the full group-planning job is complete.

## Rollout

Use staged capability flags even if the first implementation is local:

1. TikTok URL -> caption -> candidate confirmation.
2. Local persistence and close-zoom pins.
3. Instagram text/screenshot evidence.
4. Personal density zones.
5. Optional provider/LLM experiments behind server-side configuration.

The feature should initially be available to internal testers with deterministic fixtures and a
small consented evaluation dataset before live provider credentials are enabled.

## Decisions and question history

| Question | Decision | Rationale |
|---|---|---|
| Personal or community map? | Personal saves first. | Proves the core saved-interest job without accounts, moderation, privacy aggregation, or discovery-feed drift. |
| Link ingestion? | Explicit share/paste only. | Consent-based, reliable, and compatible with platform restrictions. |
| Density signal? | Confirmed mapped saves. | Avoids false precision and unconfirmed extraction noise. |
| Ambiguous matches? | Confirm before mapping. | Trust is more important than apparent automation. |
| Density visual? | Discrete emerald size/opacity levels. | Fits the current no-gradient visual system. |
| Instagram fallback? | Text or optional screenshot with on-device OCR. | Instagram oEmbed cannot legally be used as extraction input. |
| Video input? | URL first; user-selected/shared video as an optional fallback. | Preserves the easiest path while allowing stronger evidence without Plandit downloading social media. |
| Video processing? | On-device only for the MVP. | Avoids media upload/retention, limits storage to short-lived staging, and keeps the cloud contract text-only. |
| Third-party social scrapers? | Do not integrate Apify or another scraper into the approved core; preserve a provider interface only. | Apify can return useful captions/transcripts, but platform-policy, media-download, third-party actor, and dataset-retention risks require separate legal/privacy approval before even an internal spike. |
| Persistence? | Local-first SwiftData. | Works without accounts and makes personal saves durable. |
| Backend framework? | Django modular monolith with PostgreSQL, deployed on Railway. | Gives the team one API/data/admin boundary and fits provider integration, evaluation, and future operational tooling without introducing Supabase as a second control plane. |
| Analytics platform? | Keep analytics out of this feature; PostHog Cloud is the selected future candidate. | The extraction MVP needs a strict coarse-event allowlist first, and no analytics SDK is necessary to prove the save-to-map flow. |
| External services? | Evaluate options; approve before adding. | The repository requires explicit approval for services, paid APIs, and new dependencies. |
| Worktree base? | `origin/ios-scaffold`. | Keeps planning independent of dark-mode PR #3. |
| Persona-requested no-saves/group features? | Keep this dossier focused; create separate future briefs. | They are important but have different users, systems, risks, and acceptance programs from extraction/density. |

## Approval

Status: **Pending consolidated dossier approval.**
