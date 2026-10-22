# Saved-place extraction implementation plan

## Delivery strategy

Land six coherent slices. The first creates a complete fixture-backed path—share/paste, durable
state, candidates, confirmation, relaunch, and pin—without a live external dependency. Later slices
replace only stable interfaces and can be enabled or rolled back independently.

The first product milestone is narrower than the full six-slice feature: a supported URL or
user-provided video must produce up to three place-name/location candidates and persist an explicitly
confirmed place. Density and enriched operational/cost details follow only after this core path is
proven.

No implementation starts until the consolidated dossier is approved. Live-service work additionally requires the Django package set, Railway deployment details,
provider, billing, credentials, attribution, abuse protection, and retention approval.

## Source and authority

- Product behavior and scope: [01-brief.md](01-brief.md).
- System boundaries and contracts: [02-architecture.md](02-architecture.md).
- Candidate file/module layout: [03-scaffolding.md](03-scaffolding.md).
- Platform/provider facts: [00-research.md](00-research.md).
- Requirement acceptance and completion evidence: the verification table in this document.
- Canonical brand and visual language: `docs/brand_position.md` and `docs/style_guide.md`; do not
  edit either without owner sign-off.

When code and documents conflict, stop and back-patch the approved dossier or code before continuing.
Do not silently reinterpret a requirement. Unknown provider/platform behavior is tested against
official documentation or a sandbox; it is not filled in with scraping or guessed fallback data.

## Pre-build gates

1. Approve this dossier and assign iOS, backend, security, and feature-integration owners.
2. Confirm the top-level `backend/` location, supported Python/Django versions, API toolkit,
   dependency lock format, Railway CI/deployment commands, secret management, and deployment owner.
3. Approve the place-provider benchmark method and billing ceiling; do not add credentials yet.
4. Confirm whether dark-mode PR #3 lands before this work. If it does, rebase before the first UI
   slice and use its adaptive tokens rather than resolving map/saved-view conflicts later.
5. Approve the consented labeled evaluation dataset format and storage location.
6. Create tracking issues/PRs so each slice has one integration owner and safe landing.

## Workstream contracts

| Workstream | Owns | Must not own | Integration contract | Review owner |
|---|---|---|---|---|
| iOS persistence/intake | SwiftData schema, repositories, App Group import, state transitions | Provider-specific HTTP or map aggregation | Domain projections and repository protocols | iOS owner |
| iOS extraction UX | Evidence, OCR, candidates, manual search, recovery UI | Raw SwiftData mutation or provider payload parsing | Feature-model intents and typed client errors | iOS owner + product owner |
| Backend resolution | OpenAPI, URL policy, oEmbed, interpretation, place adapters | iOS state/UI or screenshot processing | Versioned request/response fixtures | Backend owner |
| Map/density | Grouped annotations, camera buckets, density zones, zone selection | Persistence and network calls | Pure confirmed-coordinate input | iOS map owner + design owner |
| Evaluation/testing | Labeled examples, contract tests, failure matrix, integrated UI tests | Product-scope changes | Verification table and immutable fixtures | Independent testing owner |
| Integration | Dependency construction, flags, migrations, rollout, cleanup | Redefining owned contracts without review | Approved interfaces and evidence links | Feature integration owner |

The OpenAPI document is authoritative for transport. Swift/backend DTOs and fixtures are consumers.
The SwiftData schema is authoritative only inside the iOS data adapter; UI and density code consume
domain models. The density engine owns cell/version math, while the map view owns presentation.

## Slice 1 — Durable fixture-backed save path

**Outcome:** A supported shared/pasted link becomes a durable queued record, fixture candidates can
be confirmed, and the confirmed place survives relaunch and appears as a grouped Saved pin.

**Scope and files**

- Add shared supported-source parsing and typed validation in `ios/Shared/Sharing/`.
- Replace destructive inbox drain with peek/import/acknowledge behavior.
- Add versioned SwiftData entities, migration plan, repositories, and domain projections under the
  proposed `Features/SavedPlaces/` structure.
- Add `SavedPlacesFeatureModel`, deterministic fixture client, clock/UUID seams, explicit states,
  candidate confirmation, manual fixture search, retry, and delete.
- Wire `ModelContainer` and dependencies in `PlanditApp`.
- Adapt Saved list/detail/add-link UI and grouped close-zoom pins.
- Preserve one-tap original-source access, visible save age, explicit unknowns, and Add to Today on a
  confirmed detail; fixture data includes address, travel estimate, availability, and cost states.
- Add unit and UI test targets in `ios/project.yml`; regenerate the Xcode project.

**Dependencies:** Dossier approval; dark-mode integration decision.

**Safe landing:** Live external resolution remains disabled. Debug/UI-test builds use named fixtures;
release builds show a clear unavailable/manual state rather than random sample matches. Existing
Today/Profile flows remain intact. Do not seed sample saves into the production SwiftData store.

**Uncertainty rule:** If SwiftData uniqueness/relationship behavior cannot enforce the documented
transaction, solve it in the repository with explicit fetch-and-merge tests; do not expose entity
workarounds to UI.

**Proof:** Verification rows SPE-1, SPE-2 client boundary, SPE-6 fixture shape, SPE-7, SPE-8, SPE-11
local recovery, and SPE-13 foundation.

## Slice 2 — Resolution contract and secure backend core

**Outcome:** A deployable but non-production Django/PostgreSQL backend validates requests and
returns deterministic contract fixtures through provider interfaces, with URL/redirect/SSRF
defenses proven independently.

**Scope and files**

- Scaffold the Django modular monolith and PostgreSQL migrations under top-level `backend/`.
- Commit `openapi.yaml`, shared JSON fixtures, error envelope, versioning, and idempotency behavior.
- Implement request validation, source URL policy, bounded redirect resolver, DNS/IP enforcement,
  egress restrictions, timeouts, payload limits, rate limiting, and content-safe logs.
- Implement deterministic evidence interpreter and fake place-provider adapter.
- Add redacted operational models/admin views for request IDs, normalized outcomes, provider,
  latency, idempotency, and quota state; do not persist source URLs or evidence.
- Add contract, security-boundary, and failure-mapping tests.
- Point the iOS fixture/live client tests at the same contract fixtures.

**Dependencies:** Approved Django package set/Railway CI; Slice 1 domain/transport expectations.

**Safe landing:** No production provider keys and no public rollout. Deploy only to an authenticated
development environment or run locally. A worker/Redis service is not added. Contract changes
require iOS consumer review.

**Uncertainty rule:** If the selected framework cannot enforce connect-time IP/redirect policy
reliably, stop and choose a supported HTTP/egress design; hostname checks alone are not sufficient.

**Proof:** SPE-2 server boundary, SPE-6 schema, SPE-11 server failures, SPE-12, and SPE-13 contract
fixtures.

## Slice 3 — Live TikTok-to-candidate path

**Outcome:** Internal testers can share/paste an available TikTok video, receive licensed place
candidates from documented metadata, confirm one, and see the durable pin.

**Scope and files**

- Benchmark approved provider candidates against the labeled dataset.
- Implement TikTok oEmbed adapter, selected place-provider adapter, candidate deduplication/ranking,
  attribution, `Retry-After`, and terms-aware field retention.
- Surface allowed address, distance/travel estimate, operational status/hours/expiry, and price/cost
  context with explicit unknowns. Travel estimates identify origin and mode. Trustworthy monetary
  data uses an amount/range plus basis; price symbols alone do not count as known cost.
- Implement provider-specific stale thresholds, visible last-checked timestamps, refresh-before-
  current behavior, and stale/unknown fallback when refresh fails.
- Wire live iOS client configuration and typed failure/retry states.
- Reconcile official short URLs to platform post IDs and safely merge duplicate unconfirmed records.
- Add provider sandbox smoke tests outside deterministic CI and record date/environment.

**Dependencies:** Slices 1–2; provider/service/billing/credential approval.

**Safe landing:** Internal capability flag defaults off in release. Fixture mode remains available.
Disabling the flag preserves all local saves and confirmation data.

**Uncertainty rule:** If deterministic interpretation misses the 90% top-three target, record the
failure categories and present alternatives. Do not add an LLM until service/privacy/cost approval.

**Proof:** SPE-1 through SPE-3, SPE-6 through SPE-8, SPE-11 through SPE-13, plus the candidate-quality
gate.

## Slice 4 — Instagram and user-provided video evidence

**Outcome:** An Instagram Reel reference or user-provided video routes to a guided details flow;
share text, typed text, corrected frame/screenshot OCR, and supported on-device audio transcription
produce candidates without fetching Instagram content or uploading media.

**Scope and files**

- Add `needsEvidence`/`readingVideo` UI, Photos/file selection, AVFoundation frame sampling, Vision
  adapters, on-device Speech adapter, progress/cancel/error behavior, editable evidence with
  provenance, and manual-search escape hatch.
- Add bounded temporary-media staging and reconciliation. Ensure screenshots/videos are held only
  for recognition, deleted after acceptance/cancellation/failure/expiry, and never logged or
  included in requests.
- Make Instagram transport omit `sourceUrl`; send only platform, approved evidence, search bias, and
  locale.
- Add fixtures for empty/incorrect OCR, repeated frame text, spoken-only place clues, denied Photos
  or Speech permission, unavailable on-device transcription, unsupported/oversized media,
  cancellation, interrupted processing, cleanup, offline editing, and relaunch with saved corrected
  text.

**Dependencies:** Slices 1–3 interfaces; no new cloud media service.

**Safe landing:** Capability flags can hide screenshot/video selection while keeping URL metadata,
typed evidence, and manual search. TikTok behavior is unaffected.

**Uncertainty rule:** If Vision quality is poor on the consented examples, improve correction UX or
support typed text; do not upload media as an unapproved fallback.

**Proof:** SPE-1, SPE-4 through SPE-8, SPE-11 through SPE-13, SPE-19, and SPE-20.

## Slice 5 — Personal density map

**Outcome:** Confirmed personal saves render as accessible grouped pins at close zoom and discrete
emerald density zones at wider zoom; tapping a zone scopes the Saved experience to its members.

**Scope and files**

- Implement the pure versioned Web Mercator density engine and camera-scale buckets.
- Add grouped same-place pins with save counts.
- Add visible 7-day, 30-day (default), and All density windows based on local `savedAt`.
- Add MapKit density annotations, discrete level styling, selection/zoom/filter behavior, VoiceOver
  labels, and reduced-motion-safe transitions.
- Measure main-thread work and move calculation off-main if the target dataset misses the latency
  gate.

**Dependencies:** Slice 1 confirmed-place projections; approved style tokens; dark-mode branch
integration if merged.

**Safe landing:** A capability flag switches between grouped pins and density presentation. Any
density error falls back to grouped pins. No persistence migration is required to disable it.

**Uncertainty rule:** Tune only camera thresholds and approved discrete sizes during usability
testing. Do not change the signal to public data, introduce gradients, or add a geospatial library
without approval.

**Proof:** SPE-9, SPE-10, SPE-13, plus performance/accessibility rows.

## Slice 6 — Integrated rollout and legacy cleanup

**Outcome:** The full changed flow is verified, fake random extraction is removed, internal rollout
is controlled, and operational/provider obligations have owners.

**Scope and files**

- Remove `StubPlaceExtractor`, random sample assignment, and production sample seeding.
- Reconcile active states after termination, verify migrations, and test delete/reference cleanup.
- Run the complete deterministic suite, provider sandbox checks, candidate evaluation, accessibility
  checks, offline/relaunch checks, and changed Today/Profile flows.
- Complete privacy manifest/App Store disclosure review, attribution review, runbook, key rotation,
  quota/billing alerts, feature flags, and rollback exercise.
- Independent code review and integrated completion review compare behavior to this dossier.

**Dependencies:** All prior enabled slices and fresh provider evidence.

**Safe landing:** Rollout progresses fixture/internal -> small tester cohort -> approved wider cohort.
Backend/provider flags can stop new resolution without removing local confirmed saves.

**Uncertainty rule:** Any open `must_fix`, security boundary failure, policy ambiguity, migration data
loss, or failed acceptance row blocks PR/rollout.

**Proof:** Every verification row complete with linked evidence.

## Verification table

Evidence/status is intentionally empty until implementation. Commands may be refined for the chosen
simulator/backend framework, but any replacement must prove the same behavior. The backend test
command is a pre-build decision and remains a visible blocker rather than an invented tool choice.

| Requirement | Acceptance/failure case | Command/observation | Owner | Evidence/status |
|---|---|---|---|---|
| SPE-1 | Share extension and paste accept supported TikTok full/short video and Instagram Reel formats; unsupported hosts/paths show guidance. | `xcodebuild test -project ios/Plandit.xcodeproj -scheme Plandit -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:PlanditTests/SupportedSocialURLTests -only-testing:PlanditUITests/SavedPlaceExtractionFlowTests` | iOS owner | Pending |
| SPE-1 | Same exact canonical source imported twice creates one local record; same TikTok post through short/full URLs merges only while unconfirmed. | Repository/importer integration tests plus record-count observation after relaunch. | iOS owner | Pending |
| SPE-2 | Client rejects HTTP, credentials, bad ports, lookalike/unsupported hosts, malformed IDs, and tracking-only URLs before network. | `SupportedSocialURLTests` fixture matrix with network spy asserting zero calls. | iOS owner | Pending |
| SPE-2, SPE-12 | Server rejects every unsafe redirect/DNS/IP case, validates each hop, bounds size/time/redirects, and permits documented TikTok oEmbed only. | `cd backend && python manage.py test tests.security tests.contract`; independent security review of egress behavior. | Backend + security owners | Pending |
| SPE-3 | Available TikTok fixture/live sandbox response uses documented oEmbed fields and shows attribution; unavailable/private/rate-limited cases map to typed states. | Contract tests; recorded sandbox smoke with date, source category, response code, and redacted evidence. | Backend owner | Pending |
| SPE-4 | Instagram enters `needsEvidence`; backend request omits URL and includes only approved text/platform/bias/locale. | iOS integration test with request spy plus backend schema rejection test for Instagram `sourceUrl`. | iOS + backend owners | Pending |
| SPE-5 | Screenshot OCR runs locally, text is editable, cancellation/empty result recover, and image bytes never enter persistence/network/log spies. | Vision adapter/unit tests using owned fixtures; UI flow; payload/persistence/log spy assertions. | iOS owner | Pending |
| SPE-5, SPE-19 | User-provided video is validated and processed outside the share extension; sampled-frame OCR and supported on-device audio transcription produce editable evidence, while denied/unavailable recognition retains typed/manual fallback. | AVFoundation/Vision/Speech adapter tests with owned media fixtures; UI tests for permissions, cancellation, and fallback. | iOS owner | Pending |
| SPE-6 | Responses contain no more than three deduplicated candidates with required display, confidence/evidence, provider identity, and attribution fields; manual search is always reachable. | OpenAPI contract tests and candidate-confirmation UI test. | Backend + iOS owners | Pending |
| SPE-6, SPE-13 | Correct place appears in top three for at least 90% of approved labeled examples. | `cd backend && python manage.py test tests.evaluation`; report includes dataset version, adapter version, failures, and date. | Evaluation owner | Blocked on approved dataset/provider |
| SPE-7 | No candidate, processing item, or failed item contributes a map pin/density record; explicit candidate confirmation does. | Feature-model/repository tests plus UI assertion before/after confirmation. | iOS owner | Pending |
| SPE-8 | Source/state/evidence/candidates/confirmed place survive process termination and offline relaunch; schema migration preserves prior data. | Disk-backed SwiftData integration test, migration fixture test, airplane/offline simulator observation. | iOS owner | Pending |
| SPE-9 | Close zoom groups same-place confirmed saves; wider zoom yields deterministic versioned cells and four discrete levels with no gradient. | `SavedPlaceDensityEngineTests` golden fixtures plus visual inspection in light/dark if dark-mode PR is merged. | Map + design owners | Pending |
| SPE-9 | Density calculation and render update meet an agreed interactive target of under 250 ms for 500 confirmed saves on the baseline simulator/device. | XCTest measure/signpost run; record device/simulator, OS, dataset, median and p95. | Map owner | Pending |
| SPE-10 | Tapping a zone fits/scopes exactly its member saves; clearing selection restores all saves; VoiceOver label states save count/area without trend language. | UI test and manual VoiceOver changed-flow check. | iOS + accessibility reviewers | Pending |
| SPE-11 | Offline, no-candidate, unavailable source, throttling, provider outage, decode failure, interrupted import, stale response, retry, and delete each preserve or remove data as specified. | Failure-matrix unit/integration tests; kill/relaunch UI scenario; request-attempt spy. | Integration owner | Pending |
| SPE-12 | No code path downloads social media, scrapes pages, uses undocumented endpoints, leaks keys, uploads screenshots, or logs evidence/URLs/coordinates. | Dependency/endpoint inventory, secret scan, log-capture tests, privacy review, independent security review. | Security + integration owners | Pending |
| SPE-13 | Deterministic fixtures cover happy paths, variants, failures, seams, and changed Today/Profile behavior; UI tests use no live service. | Full iOS suite, approved backend suite, contract fixture checksum, and changed-flow checklist. | Testing owner | Pending |
| SPE-14 | Representative TikTok runs finish below 30 seconds median/two minutes p95 and Instagram evidence runs below two minutes p95 without manual web research. | Timed usability protocol and signposts; report device/network, sample size, median/p95, correction count, and abandonment. | Product research + integration owners | Pending |
| SPE-15 | Confirmed detail shows saved age/source/full address/travel estimate with selected origin and mode/reliable availability/actionable cost/Add to Today. Trustworthy monetary data uses an amount or range plus basis; price symbols alone do not pass. Every missing field says unknown and no screen labels price as a complete day total. | Fixture matrix UI tests plus manual content review and changed Add-to-Today flow. | iOS + product owners | Pending |
| SPE-16 | 7-day, 30-day default, and All controls deterministically change zone counts and visibly identify the active window. | Density engine date-boundary tests and map UI test. | Map owner | Pending |
| SPE-17 | Basic intake/confirmation/manual save/map has no paywall; disabling/quota-limiting external resolution preserves local data and exposes manual completion with clear copy. | Configuration/UI tests and product/paywall audit. | Product + integration owners | Pending |
| SPE-18 | Operational status, hours, event expiry, and monetary context show last-checked time; stale fields refresh under provider policy before appearing current, and refresh failure renders the affected field stale/unknown without losing place identity. | Backend provider-policy tests for threshold boundaries and refresh failures; iOS fixture/UI assertions for fresh, stale, and unknown labels. | Backend + iOS + product owners | Pending |
| SPE-19 | Video type/size/duration limits are enforced; no media bytes reach Django or durable app storage; staged copies are removed after success, cancellation, failure, process interruption, and expiry. | Temporary-media integration tests, launch reconciliation test, filesystem/network/log spies, and privacy review. | iOS + security owners | Pending |
| SPE-20 | A supported URL or owned video fixture returns no more than three candidate place names/locations, manual correction remains available, and only explicit confirmation creates the durable place. | Core end-to-end UI test using shared contract fixtures; labeled top-three evaluation report. | Integration + evaluation owners | Pending |
| Rollout | Flags independently disable live TikTok, Instagram screenshot evidence, and density while confirmed local saves remain usable. | Configuration tests and documented rollback exercise in internal environment. | Integration + operations owners | Pending |
| Accessibility | Dynamic Type, contrast, non-color status cues, touch targets, VoiceOver order/labels, and Reduce Motion remain usable across new screens/map states. | Accessibility Inspector/manual matrix and targeted UI assertions. | Design + accessibility reviewers | Pending |
| Regression | Today planning, Saved navigation, map tab switching, share-extension completion, and Profile remain functional. | Full iOS test suite plus manual changed-flow smoke on signed simulator build. | Integration owner | Pending |

Separate planning/group-sharing features must verify full day cost, dietary constraints, exact transit
guidance, meeting points, and browser sharing before Plandit claims those outcomes. They are not
acceptance proxies for this extraction feature.

## Testing checkpoint

After Slice 4 and before density integration, an independent testing review should inspect variants,
failures, seams, and completion evidence—not re-design the architecture. It must specifically look
for:

- destructive share acknowledgment or duplicate import races;
- stale async results after retry/delete;
- accidental Instagram URL/screenshot transmission;
- confirmation bypasses;
- provider payload leakage into UI/storage/logs;
- offline/relaunch state corruption;
- ambiguous manual-search exits.

All required findings are back-patched into this plan and resolved before Slice 5. A second integrated
completion review is required in Slice 6 before PR.

## PR and integration order

Preferred PR order mirrors slices. Slices 1 and 2 may proceed in parallel only after OpenAPI/domain
field names are agreed; neither may invent incompatible transport fields. Slice 3 integrates both.
Slices 4 and 5 may branch from Slice 3 and land in either order because OCR/evidence and density share
only stable domain projections. Slice 6 lands last.

Each PR must:

- reference its verification rows;
- include passing focused proof and independent review;
- state feature-flag/default behavior and rollback;
- avoid unrelated cleanup;
- update dossier progress/evidence;
- land in dependency order without leaving fake production success paths.

## Human approval

**Consolidated dossier approval:** Pending.

Approval authorizes planning direction only. It does not approve a paid API, new library, backend
service, production credential, analytics SDK, hosted model, or public community-density feature.
