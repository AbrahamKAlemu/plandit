# Potential implementation scaffolding

This is a proposed file/module shape, not implementation. Names may change during build kickoff, but
the boundaries in [02-architecture.md](02-architecture.md) should remain intact.

## iOS source layout

```text
ios/
├── Shared/
│   └── Sharing/
│       ├── SupportedSocialURL.swift
│       ├── ShareInbox.swift
│       └── IncomingShare.swift
├── Plandit/
│   ├── App/
│   │   └── AppDependencies.swift
│   ├── Features/
│   │   ├── SavedPlaces/
│   │   │   ├── Domain/
│   │   │   │   ├── SavedItem.swift
│   │   │   │   ├── ExtractionState.swift
│   │   │   │   ├── PlaceCandidate.swift
│   │   │   │   ├── ConfirmedPlace.swift
│   │   │   │   └── SavedPlacesFeatureModel.swift
│   │   │   ├── Data/
│   │   │   │   ├── Persistence/
│   │   │   │   │   ├── SavedItemEntity.swift
│   │   │   │   │   ├── PlaceEntity.swift
│   │   │   │   │   ├── PlaceCandidateEntity.swift
│   │   │   │   │   └── SwiftDataSavedItemRepository.swift
│   │   │   │   └── Network/
│   │   │   │       ├── PlaceResolutionClient.swift
│   │   │   │       ├── LivePlaceResolutionClient.swift
│   │   │   │       └── FixturePlaceResolutionClient.swift
│   │   │   ├── Services/
│   │   │   │   ├── ScreenshotTextRecognizer.swift
│   │   │   │   ├── VideoEvidenceExtractor.swift
│   │   │   │   ├── VideoFrameTextRecognizer.swift
│   │   │   │   ├── OnDeviceAudioTranscriber.swift
│   │   │   │   ├── TemporaryMediaStore.swift
│   │   │   │   └── PendingShareImporter.swift
│   │   │   └── UI/
│   │   │       ├── AddLinkSheet.swift
│   │   │       ├── EvidenceEditorView.swift
│   │   │       ├── CandidateConfirmationView.swift
│   │   │       ├── ManualPlaceSearchView.swift
│   │   │       ├── SavedSheet.swift
│   │   │       └── SavedPostDetailView.swift
│   │   └── Map/
│   │       ├── SavedMapAnnotation.swift
│   │       ├── DensityZone.swift
│   │       ├── SavedPlaceDensityEngine.swift
│   │       └── PlanditMapView.swift
│   └── Supporting/
│       └── PreviewFixtures/
├── PlanditTests/
│   ├── Sharing/
│   ├── Persistence/
│   ├── SavedPlaces/
│   ├── Networking/
│   └── Map/
└── PlanditUITests/
    └── SavedPlaceExtractionFlowTests.swift
```

The current `PlanditStore` can retain Today/Profile responsibilities while `saved` and extraction
logic move into `SavedPlacesFeatureModel`. Avoid a repository-wide state rewrite in the same slice.

## Django backend layout

The selected backend is a Django modular monolith with PostgreSQL, deployed on Railway. This is
proposed scaffolding rather than generated code:

```text
backend/
├── manage.py
├── pyproject.toml
├── config/
│   ├── settings/
│   │   ├── base.py
│   │   ├── development.py
│   │   └── production.py
│   ├── urls.py
│   ├── asgi.py
│   └── wsgi.py
├── contracts/
│   ├── openapi.yaml
│   └── fixtures/
│       ├── place-resolution/
│       └── errors/
├── apps/
│   ├── resolution/
│   │   ├── api/
│   │   ├── domain/
│   │   ├── services/
│   │   ├── providers/
│   │   ├── models.py
│   │   └── admin.py
│   └── operations/
│       ├── models.py
│       └── admin.py
└── tests/
    ├── contract/
    ├── security/
    ├── provider/
    └── evaluation/
```

`resolution/domain` and `resolution/services` stay independent of Django request objects and
provider payloads. Only the adapter for the approved provider ships. Challenger adapters may exist
in a local benchmark harness without production credentials.

The API toolkit and schema-generation package remain build-kickoff approvals; selecting Django does
not silently approve Django REST Framework, Django Ninja, Celery, Redis, or any other dependency.
The default validation command is Django's built-in test runner until an approved package changes
it.

## Railway service shape

```text
Railway project
├── web       Django ASGI/WSGI service
├── postgres  managed PostgreSQL
└── worker    deferred until a measured asynchronous workload exists
```

Railway environment variables own Django secrets, database credentials, provider credentials, and
deployment configuration. Migrations run as an explicit release/deploy step rather than on every
web-process startup. Production logs contain request IDs and normalized codes, never evidence,
source URLs, provider payloads, screenshots, or exact coordinates.

PostgreSQL initially stores only redacted operational records needed for idempotency, quotas,
support, and evaluation bookkeeping. SwiftData remains the user-data store until a separately
approved accounts/sync feature defines cloud ownership and conflict behavior.

## Domain protocols

```swift
protocol SavedItemRepository: Sendable {
    func importSource(_ source: SupportedSocialURL, sharedText: String?) async throws -> SavedItem
    func item(id: UUID) async throws -> SavedItem?
    func items() async throws -> [SavedItem]
    func transition(
        id: UUID,
        expected: ExtractionState,
        attemptID: UUID?,
        mutation: SavedItemMutation
    ) async throws -> SavedItem
    func delete(id: UUID) async throws
}

protocol ScreenshotTextRecognizing: Sendable {
    func recognizeText(in imageData: Data) async throws -> String
}

protocol VideoEvidenceExtracting: Sendable {
    func extractEvidence(from media: TemporaryMediaReference) async throws -> VideoEvidence
}

protocol PlaceResolutionClient: Sendable {
    func resolve(_ request: ResolutionRequest) async throws -> ResolutionResponse
    func search(_ request: ManualPlaceSearchRequest) async throws -> [PlaceCandidate]
}

protocol SavedPlaceDensityCalculating: Sendable {
    func presentation(
        for saves: [ConfirmedSaveCoordinate],
        cameraScale: MapCameraScale
    ) -> SavedMapPresentation
}
```

Concrete error enums must distinguish validation, evidence, offline, throttling, provider outage,
no-candidate, decode, persistence, and unknown failures. UI copy maps from local error codes rather
than exposing external messages.

## Dependency construction

`AppDependencies` should construct:

1. SwiftData `ModelContainer`.
2. SwiftData repository actors.
3. URL session configured with ephemeral caches/timeouts appropriate to API data.
4. Live or fixture `PlaceResolutionClient`.
5. Vision OCR adapter.
6. Pending-share importer.
7. `SavedPlacesFeatureModel`.

Previews and tests construct the same feature model with in-memory repositories, fixture clients,
and a deterministic clock/UUID source. Xcode UI tests launch with arguments that select a fixture
scenario; they must not call TikTok or a paid place provider.

## Contract fixture examples

Maintain checked-in fixtures for:

- TikTok caption with exact venue.
- TikTok caption with venue plus neighborhood.
- TikTok caption with multiple mentioned places.
- TikTok deleted/private/unavailable.
- Instagram evidence from typed text.
- Instagram evidence from corrected OCR.
- User-provided video with place name in an on-screen overlay.
- User-provided video with place name/neighborhood only in spoken audio.
- Repeated overlay text across sampled frames.
- Unsupported/oversized video, denied Speech permission, unavailable on-device recognition, empty
  evidence, cancellation, interrupted processing, and abandoned temporary-file cleanup.
- No candidates.
- Provider rate limit with `Retry-After`.
- Fresh, stale, refresh-failed, and removed operational/cost fields.
- Known cost amount/range with per-person, admission, or typical-item basis.
- Duplicate provider results.
- Malformed and oversized responses.
- Unsafe short-link redirects.

Every fixture declares expected candidate IDs/order and whether confirmation can proceed. A separate
consented labeled dataset may store derived, non-sensitive expected labels; do not commit copyrighted
media, private screenshots, access tokens, or provider payloads whose terms prohibit retention.

## Database migration posture

The scaffold currently has no durable saved-place schema, so the first SwiftData schema is version
1. Even so, define a `VersionedSchema` and `SchemaMigrationPlan` immediately. This prevents the first
production change from requiring a persistence rewrite and makes migration tests possible.

Sample content should be inserted only into preview/in-memory stores. Production startup must never
seed fake saved places into the user's persistent container.

## Density implementation sketch

```text
input confirmed save coordinates
  -> filter by selected saved-at window (7 days / 30 days / all)
  -> choose cell-size bucket from camera scale
  -> Web Mercator project
  -> integer quantize x/y by versioned cell size
  -> group saves by cell key
  -> compute weighted centroid and member IDs
  -> map count to level 1...4
  -> stable sort for deterministic rendering/tests
```

At close zoom, group by confirmed `PlaceEntity.id` instead of grid cell. The density engine is a pure
function and must not know about SwiftData, network providers, or SwiftUI.

## Build-kickoff checklist

- Confirm supported Python/Django versions, API toolkit, dependency lock format, and Railway
  deployment/CI commands.
- Approve the public-client abuse-protection design before exposing live provider calls.
- Benchmark Google, Foursquare, and Apple correction with the same consented labeled queries.
- Approve provider, billing ceiling, credentials process, attribution, and retention policy.
- Decide whether deterministic interpretation passes the top-three recall gate.
- Approve any new library or hosted model before manifest changes.
- Confirm dark-mode PR integration order if both branches will touch map/saved UI files.
- Create Xcode unit/UI test targets in `project.yml` before feature code.
- Confirm separate owners/briefs for full budget/transit planning and browser-based group sharing;
  do not hide those product gaps inside extraction.
