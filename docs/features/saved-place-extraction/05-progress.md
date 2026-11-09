# Saved-place extraction progress

## Summary

The approved compliant core milestone is extended on `feature/direct-social-import`.
Plandit accepts supported TikTok/Instagram URLs or a user-selected video, extracts permitted
evidence directly from the exact shared public post, produces place candidates, auto-saves only a unique
exact-address-corroborated match, and otherwise requires confirmation. It
persists confirmed saves locally with canonical source and MapKit identity. The Django endpoint
keeps direct extraction behind a kill switch and does not retain source URLs or evidence.

## Attention needed

- The current persona round is complete but not cleared: Marcus's no-saves request conflicts with
  the focused planner scope, and Andre requires source/event recency before shipping.
- Live place-provider selection, billing, production credentials, public-client abuse protection,
  attribution/retention policy, Railway deployment commands, and the evaluation dataset remain
  separate approval gates.
- The EnsembleData TikTok integration remains development-only. The local Django endpoint and
  Debug simulator client work for the Chubby Bowls test URL, but production approval and public
  abuse controls remain pending.
- A direct exact-post caption adapter now handles owner-approved TikTok and Instagram URLs behind
  `SOCIAL_PAGE_EXTRACTION_ENABLED`. Ensemble Data remains an optional disabled TikTok fallback.
- Configured release/device builds use the authenticated production evidence endpoint; missing
  production configuration falls back to the existing metadata/manual path.
- Database-backed endpoint tests still require PostgreSQL on port 5433. Focused iOS tests require
  the repository's Xcode 26 toolchain; Xcode 16.4 stops on the pre-existing mutable `Sendable`
  fixture in `SyncReviewTests.swift`.
- Direct video sharing into the share extension is not implemented; video selection is available
  inside the app.

## Documents

- [Research](00-research.md)
- [Brief](01-brief.md)
- [Brief review history](01-brief_reviews.md)
- [Architecture](02-architecture.md)
- [Potential scaffolding](03-scaffolding.md)
- [Implementation plan and verification](04-plan.md)
- [Progress](05-progress.md)
- [Provider evaluation](06-provider-evaluation.md)

## Phase status

| Phase | Status | Evidence |
|---|---|---|
| Platform/API research | Complete | [00-research.md](00-research.md) |
| Brief | Draft complete | [01-brief.md](01-brief.md) |
| Architecture | Draft complete | [02-architecture.md](02-architecture.md) |
| Scaffolding | Draft complete | [03-scaffolding.md](03-scaffolding.md) |
| Plan and verification | Draft complete | [04-plan.md](04-plan.md) |
| Persona review | Overridden for TestFlight | Round 3: Sofia, Amara, and Grace approve; Marcus and Andre's blocking findings overridden by the product owner on 2026-11-09, not fixed. See [history](01-brief_reviews.md) |
| Consolidated human approval | Approved for core milestone | User approved the fixture-backed URL/video-to-confirmed-place build on 2026-10-19 |
| Implementation | Complete for direct-caption slice | Uncommitted changes on `feature/direct-social-import`; no PR created |
| Verification | Partial for direct-caption slice | 22 focused backend tests, Ruff, Django checks, app build, and diff check pass; PostgreSQL and Xcode 26 suites remain pending |
| Independent code/security review | Complete for direct-caption slice | URL-boundary, cache, address-corroboration, canonical-dedup, provider-identity, and changed-flow findings resolved |

## Decisions

| Decision | Status |
|---|---|
| Personal confirmed saves, not public/community density | Selected |
| Explicit share/paste only | Selected |
| TikTok official oEmbed metadata | Selected |
| Instagram share text, typed text, screenshot, or user-provided video; URL remains local | Selected |
| URL-first intake with optional user-provided video fallback | Selected |
| Video frame OCR and supported audio transcription run on-device | Selected |
| Apple network Speech fallback is allowed only in Debug simulator builds; release/device builds remain on-device-only | Selected for demo testing |
| Video is temporary, never uploaded, and deleted after evidence extraction | Selected |
| Build compliant core with an unused scraper-provider seam; no Apify dependency or calls | Selected |
| Confidence-based map population | Selected on 2026-11-08: one unique exact-address-corroborated candidate auto-saves; all weaker/ambiguous results require confirmation |
| iOS-only first release | Selected on 2026-11-08; Android deferred for release simplicity |
| Show up to three compact found-place cards with name and one-line address | Selected |
| “Not the right one?” opens separate optional name and address fields; at least one is required | Selected |
| Video results are candidate-first; raw OCR/transcript stays hidden unless the user reviews or corrects extracted details | Selected |
| Local-first atomic JSON snapshot shared with the planner | Selected; supersedes the extraction-only SwiftData runtime |
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
| Evaluate URL acquisition providers | Complete | [Provider evaluation](06-provider-evaluation.md) ranks development and production options and defines a twenty-URL benchmark |
| Build EnsembleData evaluation adapter | Complete (live spike) | Direct post-info call with video download disabled, short-link resolution, TikTok CDN subtitle allowlist, JSON/WebVTT parsing, management command, tests, and successful Chubby Bowls live trial |
| Build direct public-caption adapters | Complete | TikTok hydration and Instagram Open Graph parsers, bounded allowlisted redirects, 2 MB response cap, endpoint cache/throttle/kill switch, and live verification against three owner-supplied URLs |
| Add confidence-based auto-save | Complete | A single MapKit candidate auto-saves only when its address matches the one complete evidence address by house number/range, street token, and state; ambiguous results retain confirmation |
| Wire EnsembleData into the Debug simulator | Complete (local evaluation) | Debug simulator calls a DEBUG-gated localhost endpoint, falls back to TikTok oEmbed when unavailable, keeps provider evidence search-only, and uses a five-minute in-memory cache to avoid duplicate paid retries |
| Prioritize structured caption addresses | Complete | Double-space-separated creator caption fields now produce a place + street + city query before noisy prose; the Lululala / 139 Hester St case and cue-separated captions have regression coverage |
| Associate separated venue and address signals | Complete | Venue handles explicitly described as businesses and spoken `called` names are positionally paired with the nearest following address; creator handles, repeated names, and multi-venue captions have regression coverage |
| Associate pinned venue headings with later addresses | Complete | Instagram captions using a standalone `📍VENUE` heading now pair it with the nearest complete address, including Open Graph wrappers such as `account on date: "📍VENUE`. Reel `DHZYjjnPKez` produces `OREGANO 102 Berry St Brooklyn, NY 11249`, verified through the full local-backend-to-simulator-MapKit path. Re-sharing an unresolved canonical URL retries extraction instead of returning the stale failure. |
| Prevent cross-URL evidence reuse | Complete | The iOS POST request bypasses URLCache and the development endpoint returns `Cache-Control: no-store`, while the intentional source-URL-keyed five-minute server cache remains enabled |
| Handle provider daily limits | Complete | EnsembleData HTTP 495 is classified as a daily quota limit; URL-only saves keep the link and immediately offer manual details plus Photos/Files video processing in place, while useful share text still resolves automatically |
| Resolve complete addresses independently | Complete | Full postal addresses, including Square/Sq suffixes, receive reserved MapKit searches before optional name combinations; `stopped by` venue cues and one-candidate-per-query behavior preserve corroborating searches |
| Validate returned house numbers | Complete | Address-based MapKit candidates must match the extracted street-number or overlapping range; prices and unit numbers cannot satisfy the guard, and `Place Name 📍 Address` blocks provide corroborating name queries |

## EnsembleData live trial

On October 22, 2026, the development adapter processed
`https://www.tiktok.com/t/ZTfDj7vmC/`:

- Resolved canonical URL:
  `https://www.tiktok.com/@travelwithchyna/video/7655467577765793037`
- EnsembleData endpoint cost: 2 provider units.
- `download_video=false`.
- Creator caption included `Chubby Bowls`, `809 Broadway`, `New York, NY 10003`, and
  `Union Square`.
- English TikTok platform subtitles were available from `v16-cla.tiktokcdn-eu.com`.
- Subtitle transcript included the venue, Broadway address, 14th Street, and Union Square.
- No LLM was required to obtain or understand the decisive location evidence.

| Obtain consolidated human approval | Complete for core milestone | Fixture-backed core build approved; live provider/API remains a separate gate |
| Implement durable URL intake and confirmation | Complete | Shared atomic snapshot persistence, strict canonical URLs, deterministic candidates, explicit confirmation, backward-compatible decoding, and relaunch coverage |
| Implement temporary on-device video evidence | Complete | AVFoundation frame sampling, Vision OCR, supported on-device Speech transcription, review-before-resolution, and cleanup |
| Add direct Photos video selection | Complete | Native Photos picker plus Files fallback, pre-copy type/size validation, managed temporary storage, visible extraction errors, and picker UI coverage |
| Make simulator transcription testable | Complete | On-device Speech remains first; Debug simulator builds may use the owner-approved Apple network fallback, OCR strings provide recognition context, and unavailable transcription is visible |
| Simplify video result review | Complete | Video evidence resolves directly to up to three compact found-place cards; confirmation remains mandatory, and “Not the right one?” opens a structured name/address search |
| Verify structured place correction | Complete | UI coverage submits both name and address, verifies found-place results return, caps confirmation cards at three, and confirms the place remains unavailable to planning until selection |
| Implement Django resolution contract | Complete | Strict request validation, redacted operational records, stable idempotent response replay, admin, OpenAPI, and PostgreSQL production configuration |
| Add arbitrary-place prototype fallback | Complete | TikTok oEmbed captions and user-approved evidence fall back to on-device MapKit search when fixture aliases do not match; Instagram URL-only still requires an approved metadata source |
| Verify approved user flow | Complete | URL/evidence to candidate to confirmation to relaunch UI test passes on iPhone 16 Pro / iOS 18.6 |
| Resolve independent review findings | Complete | Persistence is transactional before in-memory success; failures become retryable; video evidence requires review; malformed JSON is rejected; request IDs replay stable candidate snapshots |

## Approval record

On 2026-10-19, the owner approved `approve_core_build` with no required changes. This authorizes
implementation of URL intake, optional temporary user-provided video processing, on-device
OCR/transcription, fixture-backed place-name/location candidates, explicit confirmation, and local
persistence.

The approval does not authorize a paid place API, cloud media upload, social-media downloading,
production credentials, or public rollout. Persona review remains deferred at the owner's request
and does not block the approved core milestone.

## Implementation evidence

| Commit | Outcome |
|---|---|
| `5092915` | Planning dossier and approved architecture |
| `3f2568e` | Durable saved-place confirmation flow |
| `85c161a` | Temporary on-device video evidence intake |
| `d64a4b1` | Django place-resolution contract |
| `c7d0d6e` | Generated backend state excluded |
| `21f1b04` | Transactional persistence, evidence review gate, request validation, and stable idempotency |
| `9461558` | Development-only EnsembleData adapter and URL support |
| `1b15bf8` | Live subtitle extraction verification and provider documentation |
| `241da4a` | Local Django endpoint, Debug simulator client, fallback behavior, ephemeral evidence, and duplicate-request cache |
| `52948bd` | Structured caption address prioritization |
| `7f11d26` | Venue and address association without creator-handle false positives |
| `79165af` | Cross-URL cache isolation |
| `7c1e7c9` | Address-first MapKit resolution |
| `29ba56f` | Extracted street-number validation |
| `4212153` | Compact found-place confirmation cards and structured name/address correction |

## Planner integration

On October 22, 2026, the extraction branch was integrated with the mapping and day-planning work
merged by `275ab652d62cb877349c3bc1a379acb70cd2128b`.

- Confirmed saved places and planner state now use one atomic `SnapshotStore` file.
- Existing snapshots from before extraction fields were added decode with safe defaults.
- `.needsConfirmation` candidates are never offered to the planner; confirming a candidate changes
  the post to `.ready`, after which it becomes `isMappable` and selectable in the `+` plan flow.
- Pending share-extension items are acknowledged only after the saved post is durably written.
- Synchronous saved-place writes cancel older debounced snapshots so stale planner/profile writes
  cannot erase an acknowledged share.
- The polished saved-place navigation, Photos/Files video intake, candidate correction UI, Today
  timeline, route loading, and plan builder coexist in the merged iOS application.
- The November 9 navigation/budget update from `origin/main` is integrated. A newly auto-mapped
  place retains its source/provider identity when added to Today, and the focused extraction,
  store, route/budget, Plan Flow, and Map/Budget UI suites pass together.
- Django retains the Supabase/DRF `/api/` application and adds the development-only extraction
  contract under `/v1/`.
- Production `/api/saved/` still uses its separate oEmbed/database matcher; promoting
  EnsembleData-backed evidence into that authenticated production path remains a later gate.

Integration verification:

- iOS application build passes.
- All `PlanditTests` unit tests pass, including old-snapshot decoding, confirmation-to-planner
  eligibility, and stale-snapshot/share-acknowledgement regression coverage.
- `SavedPlaceExtractionFlowTests` and `PlanFlowTests` pass on iPhone 16 Pro / iOS 18.6.
- All 18 extraction backend tests pass.
- All 40 pure-Python planner tests pass.
- Ruff, Django system checks, migration drift checks, and `git diff --check` pass.
- The database-backed DRF tests require the repository's PostgreSQL 15 test service because the
  migrations intentionally execute PostgreSQL row-level-security SQL; no local server was
  available on port 5433 during this integration.

The approved fixture/local milestone has no paid API usage. Production operating cost remains
dependent on the later Railway/PostgreSQL deployment and approved place provider; Apify is not part
of the implementation.

## Authenticated TestFlight extraction

On October 23, 2026, the production extraction path was prepared for a small TestFlight cohort.

- `/v1/social-evidence` now reuses Supabase JWT authentication in production and applies a
  configurable per-user throttle (`100/day` by default).
- `ENSEMBLEDATA_ENABLED` is an explicit production kill switch instead of being tied to Django
  debug mode. The provider token remains server-side.
- Release builds can silently create and refresh a Supabase anonymous session, keep it in the iOS
  Keychain, and send its bearer token to the configured HTTPS API.
- The API base URL, Supabase URL, and public Supabase client key are build settings. Missing release
  configuration degrades to TikTok oEmbed rather than making an unauthenticated paid-provider call.
- Debug simulator builds retain the localhost evidence client for development.

The iOS Debug and Release simulator builds and focused extraction tests pass. Database-backed
endpoint tests remain dependent on the repository's PostgreSQL service because its RLS migrations
cannot run on SQLite. Deployment still requires enabling Supabase anonymous sign-ins, configuring
Railway variables, and validating one authenticated request against the deployed service.
