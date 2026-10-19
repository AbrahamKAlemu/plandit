# Saved-place extraction architecture

## Summary

Build the feature as a local-first iOS workflow with a narrow, contract-first resolution service:

- The share extension remains a lightweight URL handoff boundary.
- The main app validates and durably imports each source into SwiftData before removing it from the
  App Group inbox.
- An explicit state machine coordinates URL metadata, temporary user-provided video, on-device
  frame OCR/audio transcription, place candidates, confirmation, retry, and deletion.
- A Django modular monolith on Railway owns outbound TikTok oEmbed, licensed place-provider calls,
  operational controls, and the versioned HTTP contract. PostgreSQL stores only approved
  server-side operational state; user screenshots and raw evidence are not retained.
- Only confirmed local saves feed grouped close-zoom pins and deterministic discrete density zones.

The [brief](01-brief.md) owns product requirements. The future Plan verification table will be the
acceptance source of truth rather than duplicating test cases here.

## Existing structure and reconnaissance

| Existing component | Current behavior | Architectural consequence |
|---|---|---|
| `Shared/Sharing/LinkParsing.swift` | Finds the first HTTP(S) URL and classifies any other host as `web` | Replace permissive classification with supported-host validation and canonicalization. |
| `Shared/Sharing/ShareInbox.swift` | Stores a Codable array in App Group defaults and destructively drains it | Import one record durably before acknowledgment so a launch-time crash cannot lose shares. |
| `PlanditShare/ShareViewController.swift` | Extracts URL/text and enqueues it | Keep the extension fast; add supported-link messaging but no network/OCR/persistence work. |
| `Services/PlaceExtractor.swift` | Fetches TikTok oEmbed in-app, then randomly selects sample data | Remove random matching; replace with a resolution-client protocol and deterministic fixture. |
| `Models/SavedPost.swift` | One value model combines source, extraction, place, and status | Separate persisted source/evidence/candidates/confirmation from domain/UI projections. |
| `Models/Place.swift` | Stores display fields and coordinates with a random local UUID | Add provider identity, provenance, freshness, and a stable local key. |
| `Services/PlanditStore.swift` | Owns all mutable app state and starts untracked tasks | Move saved-place work to a dedicated observable feature model backed by repositories/use cases. |
| `Features/Saved/AddLinkSheet.swift` | Accepts the first web URL and dismisses immediately | Validate platform before save and route Instagram/insufficient evidence to a details step. |
| `Features/Saved/SavedSheet.swift` | Displays four broad statuses | Render the explicit extraction states and their recovery actions. |
| `Features/Map/PlanditMapView.swift` | Draws one pin per mappable post | Consume grouped place annotations or density zones based on camera scale. |
| `project.yml` | iOS 17, no SwiftData container wiring, no test targets | Add persistence and test targets through XcodeGen during implementation. |

## System boundaries

```text
TikTok / Instagram / clipboard
             |
      Share extension
             |
   App Group pending inbox
             |
       Durable importer
             |
  SwiftData saved-place store <---- approved extracted text
             |
   SavedPlacesFeatureModel
       |              |                 |
 Django API       Density engine   Video evidence extractor
       |              |            Vision OCR + Speech
 URL policy       Map annotations
 TikTok oEmbed
 Evidence parser
 Place provider adapter
```

The Django backend never receives screenshots or video in MVP. For TikTok it receives a supported
source URL; for Instagram it receives only platform type and user-approved evidence text. Both flows
may include coarse search bias, locale, and an idempotency key. Instagram URLs remain local
references and the backend must not fetch or derive Instagram page/oEmbed content.

## Backend topology

The backend is one Django codebase and one PostgreSQL database, deployed as a Railway web service.
It remains a modular monolith rather than splitting extraction, sync, and administration into
separate services.

The MVP request path is synchronous because documented metadata and place search must fit the
two-minute user-flow budget. A Railway worker process and queue may be added later for provider
refreshes, evaluation batches, or maintenance, but no Redis/worker dependency is introduced until a
measured workload requires it.

Django owns:

- versioned `/v1` API endpoints and OpenAPI fixtures;
- request validation, URL/redirect policy, rate limiting, idempotency, and safe error envelopes;
- provider credentials and outbound adapters;
- redacted resolution-attempt records, provider quota state, capability flags, and support/admin
  views;
- future account/sync/public-link models only after their separate feature briefs are approved.

PostgreSQL may retain request ID, coarse platform type, normalized result/failure code, provider,
latency, attempt timestamps, idempotency digest, and quota/accounting data. It must not retain source
URLs, captions, user evidence, screenshots, exact search coordinates, or raw provider payloads for
this MVP. Django Admin exposes only those redacted operational fields.

The iOS app remains local-first. SwiftData owns the user's sources, approved evidence, candidates,
confirmed places, and personal density state. Supabase is not part of this feature; introducing it
later requires an explicit ownership/migration decision so clients do not write through both
Supabase and Django without one authoritative policy.

## Affected components

### Share intake

`SupportedSocialURL` becomes the shared parser used by the extension and app. It returns either a
normalized supported reference or a typed rejection. Client validation is for immediate UX; the
backend independently validates every URL before any outbound request.

The App Group queue changes from `drain()` to peek/import/acknowledge semantics:

1. Read pending entries without deleting them.
2. Canonicalize and insert-or-find the `SavedItemEntity` in SwiftData.
3. Save the model context.
4. Acknowledge only that inbox entry.

An entry has a stable UUID so acknowledgment does not depend on mutable URL text. Canonical URL
uniqueness makes repeated shares idempotent. The extension must finish quickly and does not wait for
the app, backend, or OCR.

### Saved-place feature model

Introduce a focused `@Observable @MainActor SavedPlacesFeatureModel`. It exposes immutable domain
projections and user intents while repositories and service clients perform side effects.

Representative intents:

- `importPendingShares()`
- `addLink(_:)`
- `submitEvidence(itemID:text:)`
- `recognizeScreenshot(itemID:image:)`
- `analyzeVideo(itemID:mediaReference:)`
- `resolve(itemID:)`
- `confirm(itemID:candidateID:)`
- `searchManually(itemID:query:)`
- `retry(itemID:)`
- `delete(itemID:)`

`PlanditStore` continues to own Today/Profile during this feature. Adding a confirmed place to Today
uses a small domain adapter instead of exposing SwiftData entities to planning UI.

### Persistence repositories

SwiftData is an implementation detail behind protocols:

- `SavedItemRepository`: insert/deduplicate, fetch projections, transition state, store evidence,
  candidates, confirmation, failure, and deletion.
- `PlaceRepository`: upsert a provider place by stable provider key and return local domain models.

Repositories serialize mutations and save each user-visible transition. UI does not mutate entities
directly. A deterministic in-memory implementation supports previews and unit tests.

### Extraction and place resolution

The app depends on:

```swift
protocol PlaceResolutionClient: Sendable {
    func resolve(_ request: ResolutionRequest) async throws -> ResolutionResponse
    func search(_ request: ManualPlaceSearchRequest) async throws -> [PlaceCandidate]
}
```

The live client calls the backend. A fixture client replaces the existing random stub. On each
attempt the feature model creates an attempt UUID; late results may apply only while the persisted
item still has that attempt UUID and expected state. Deleting or retrying an item invalidates prior
responses.

The Django application owns interfaces equivalent to:

- `SourceURLPolicy`
- `TikTokMetadataProvider`
- `EvidenceInterpreter`
- `PlaceSearchProvider`
- `CandidateRanker`

The first `EvidenceInterpreter` should be deterministic: normalize caption/user text, derive bounded
query hypotheses, search the place provider, deduplicate, and score by name/token overlap, category,
address/neighborhood, and coarse geographic bias. A hosted LLM may later implement the same
interface only after approval and evaluation shows the deterministic approach is inadequate.

### OCR

`ScreenshotTextRecognizing` wraps Apple Vision. Processing remains on-device:

1. User explicitly selects a screenshot.
2. Vision recognizes text.
3. The app shows editable extracted text.
4. Only user-approved text enters persisted evidence and the resolution request.
5. The screenshot is released and is not copied into Plandit's data store.

### User-provided video evidence

`VideoEvidenceExtracting` coordinates AVFoundation, Vision, and Speech outside the share extension.
The extension only records a transferable file reference or stages a bounded temporary copy in the
App Group when the source URL is not durable enough for the main app.

1. Validate an approved video type, maximum duration, and maximum byte size before staging.
2. Open the asset from the main app and sample representative frames with AVFoundation.
3. Run Vision text recognition on sampled frames and deduplicate repeated overlays.
4. Extract the audio track and request on-device Speech recognition when the device/language
   supports it and the user grants permission.
5. Combine share text, frame OCR, and transcript into editable evidence with provenance labels.
6. Delete the staged video immediately after evidence is accepted, cancelled, or fails; startup
   reconciliation removes abandoned staged files after a short approved expiry.
7. Send only user-approved text to Django.

The pipeline never downloads the media behind a TikTok/Instagram URL. URL-only remains the first
attempt; video selection appears only when permitted metadata/share text cannot identify a place or
when the user explicitly chooses it.

### Map presentation and density

The map consumes two derived models:

- `SavedPlaceAnnotation`: one confirmed place, one coordinate, one or more saved item IDs, and save
  count.
- `DensityZone`: stable cell key, display coordinate, confirmed save count, member place/item IDs,
  and discrete visual level.

At close zoom, annotations group records sharing the same confirmed local place. At wider zoom, the
density engine first filters by the selected 7-day, 30-day, or All saved-time window, then quantizes
Web Mercator coordinates into geographic cells using a versioned cell-size bucket. Suggested
prototype buckets are 400 m, 800 m, and 1,600 m; camera-scale usability testing sets the final
thresholds without changing the contract.

Visual levels are deterministic:

| Count | Level | Presentation intent |
|---:|---:|---|
| 1 | 1 | Small, light emerald circle |
| 2–3 | 2 | Medium circle |
| 4–7 | 3 | Large circle |
| 8+ | 4 | Largest, strongest approved emerald |

No gradient is used. The zone coordinate is the weighted centroid of its confirmed saves, while its
cell key remains stable during panning. Tapping a zone fits its member coordinates and scopes the
Saved list to those records. Accessibility labels state the count and area without popularity or
trend language.

## Data and state contracts

### SwiftData entities

Names are provisional scaffolding, not generated code.

#### `SavedItemEntity`

| Field | Purpose |
|---|---|
| `id: UUID` | Stable local identity and share-inbox acknowledgment target |
| `originalURL: String` | User-provided reference |
| `canonicalURL: String` (unique) | Local deduplication key |
| `platformRawValue: String` | TikTok or Instagram |
| `sourcePostID: String?` | Canonical platform identifier when safely derivable |
| `creatorHandle: String?` | TikTok attribution when returned |
| `caption: String?` | TikTok caption metadata or explicitly shared text |
| `userEvidenceText: String?` | User-corrected extraction evidence |
| `createdAt`, `updatedAt`, `savedAt` | Local lifecycle and visible density freshness |
| `stateRawValue: String` | Persisted state machine state |
| `attemptID: UUID?` | Rejects stale async responses |
| `failureCodeRawValue: String?` | Typed recovery behavior |
| `failureMessage: String?` | Safe user-facing context |
| `confirmedPlace: PlaceEntity?` | Present only after confirmation |
| `candidates: [PlaceCandidateEntity]` | Current ranked candidates |

#### `PlaceEntity`

| Field | Purpose |
|---|---|
| `id: UUID` | Stable local identity used by map and plan |
| `providerRawValue`, `providerPlaceID` | Provider identity |
| `providerKey: String` (unique) | `<provider>:<id>` upsert key |
| `name`, `categoryRawValue` | User-facing identity |
| `address`, `neighborhood` | Allowed cached display fields |
| `latitude`, `longitude` | Confirmed coordinate |
| `operationalStatus`, `hoursSummary`, `availabilityExpiresAt` | Reliable current/expiry context with explicit unknowns |
| `estimatedCostLow`, `estimatedCostHigh`, `costBasis` | Trustworthy monetary range and basis such as per person, admission, or typical item; price level alone is not actionable cost |
| `attributionName`, `attributionURL` | Provider-required attribution |
| `operationalCheckedAt`, `costCheckedAt`, `fetchedAt` | Visible freshness and provider-policy refresh decisions |

#### `PlaceCandidateEntity`

Stores the current response so confirmation survives relaunch: stable candidate ID, rank, provider
identity, display fields, coordinate, confidence band, short evidence reason, and parent item.
Candidates are replaceable cache data; confirmed places are durable user data subject to provider
terms.

Official TikTok short URLs can initially deduplicate only against the same normalized short URL.
After bounded server-side redirect resolution returns a platform post ID, the repository merges
duplicate unconfirmed records for that post. It never silently merges two independently confirmed
records.

### Extraction state machine

```text
queued
  |-- TikTok -----------------> readingMetadata
  |-- Instagram/no evidence --> needsEvidence
  |-- provided video ---------> readingVideo

readingMetadata --> findingPlaces
needsEvidence -- submit ------> findingPlaces
readingVideo --> needsEvidence --> findingPlaces
findingPlaces --> needsConfirmation --> confirmed
findingPlaces --> needsEvidence
any active state --> failed(retryTarget)
failed -- retry --> persisted retryTarget
any state -- delete --> removed and attempt invalidated
```

State changes use repository methods that verify the expected prior state and attempt UUID. Unknown
persisted enum values project to a visible migration/error state, never silently to success.

### HTTP contract

The framework-neutral contract should be committed as OpenAPI before server implementation.

`POST /v1/place-resolutions`

```json
{
  "requestId": "UUID",
  "platform": "tiktok",
  "sourceUrl": "https://www.tiktok.com/@creator/video/123",
  "evidence": {
    "userText": "optional corrected text"
  },
  "searchBias": {
    "latitude": 40.733,
    "longitude": -73.993,
    "radiusMeters": 15000
  },
  "locale": "en-US"
}
```

`sourceUrl` is required for TikTok and omitted for Instagram.

Response:

```json
{
  "requestId": "UUID",
  "source": {
    "canonicalUrl": "https://www.tiktok.com/@creator/video/123",
    "creatorHandle": "@creator",
    "caption": "caption text",
    "attributionUrl": "https://www.tiktok.com/@creator/video/123"
  },
  "candidates": [
    {
      "id": "opaque-candidate-id",
      "provider": "google",
      "providerPlaceId": "provider-id",
      "name": "Place name",
      "category": "food",
      "address": "123 Example St, New York, NY",
      "neighborhood": "East Village",
      "latitude": 40.0,
      "longitude": -73.0,
      "confidence": "high",
      "reason": "Name and neighborhood match the shared text",
      "attribution": {
        "name": "Google",
        "url": "https://maps.google.com/..."
      }
    }
  ]
}
```

`POST /v1/place-searches` supports manual search with query, locale, and coarse search bias and
returns the same candidate schema.

Errors use a stable envelope with `requestId`, code, safe message, retryability, and optional
`retryAfterSeconds`. Expected codes include:

- `unsupported_url`
- `invalid_url`
- `source_unavailable`
- `source_rate_limited`
- `evidence_required`
- `no_candidates`
- `provider_rate_limited`
- `provider_unavailable`
- `invalid_request`

The client maps codes to persisted failure/recovery states. It does not parse provider messages.

## Primary flows

### TikTok

1. Intake validates host/scheme and durably inserts a queued item.
2. The client sends the URL and coarse map/city bias to the resolution service.
3. The service revalidates the URL and calls only TikTok's documented oEmbed endpoint.
4. Normalized metadata feeds evidence interpretation and place-provider search.
5. The app persists up to three candidates and enters `needsConfirmation`.
6. The user confirms or manually searches; confirmation upserts the place and maps the item.

### Instagram

1. Intake validates the URL, persists it, and uses explicit text supplied by the share operation.
2. If evidence is insufficient, the user types/pastes clues or selects a screenshot/video.
3. Vision OCR and, for video, supported on-device Speech recognition run locally; the user
   edits/approves the evidence.
4. The backend receives approved text and platform type; the Instagram URL stays local.
5. Candidate and confirmation behavior matches TikTok.

### User-provided video

1. The share extension or Photos/file picker hands off an authorized video reference.
2. The main app stages only when needed, validates limits, and enters `readingVideo`.
3. Frame OCR and supported on-device audio transcription produce editable evidence.
4. The temporary video is deleted; approved text enters the normal candidate flow.
5. If recognition is unavailable or empty, the item remains recoverable with typed evidence and
   manual place search.

### Provider-data freshness

Provider policy defines stale thresholds separately for operational status/hours, event expiry, and
monetary context. A confirmed place may render cached identity/address offline, but current-state
fields include a visible last-checked time. Before the app presents a stale field as current, the
backend attempts a provider refresh. If refresh fails or the provider no longer supplies the field,
the response marks that field stale/unknown rather than preserving a success-shaped value.

Distance/travel estimates always display the selected origin label and travel mode. Cost accepts a
trustworthy amount or range only with a basis such as per person, admission, or typical item;
provider price levels or dollar symbols may be supplemental but cannot satisfy known-cost behavior.

### Relaunch/offline

SwiftData projects the last durable state immediately. Confirmed pins and density remain available.
Queued/finding states interrupted by termination become retryable queued states during reconciliation.
Evidence editing remains local offline; network-dependent resolution/search shows an explicit offline
state and preserves all evidence.

### Delete

Deletion invalidates the attempt UUID, removes candidate/evidence data and the source record, and
removes its contribution from pin counts/density. A shared `PlaceEntity` remains while referenced by
another saved item or a day plan; otherwise repository cleanup may remove it.

## Failure modes

| Failure | Behavior |
|---|---|
| Unsupported or deceptive URL | Reject before save/fetch with supported-source guidance. |
| App crashes during share import | Unacknowledged inbox record imports on next activation; unique canonical URL prevents duplication. |
| TikTok short-link redirect escapes allowlist | Backend aborts and returns `invalid_url`. |
| Deleted/private TikTok | Preserve source reference and user evidence; offer details/manual search. |
| Instagram has no evidence | Stay in `needsEvidence`; do not call Instagram endpoints. |
| OCR is empty or wrong | Keep editable text and allow type/paste/manual search. |
| Video is unsupported, oversized, or too long | Reject before processing with limits and retain URL/text evidence. |
| Speech permission denied or on-device recognition unavailable | Continue with share text/frame OCR and typed/manual fallback. |
| App terminates during video processing | Delete expired staged media during reconciliation and return the item to `needsEvidence`. |
| Temporary media cleanup fails | Record a local cleanup error, retry on activation, and never treat extraction as complete while media remains unexpectedly staged. |
| No candidate | Keep evidence and offer retry/manual search; do not pin. |
| Rate limit/provider outage | Persist retryable failure and honor `Retry-After`; do not spin. |
| App terminates during resolution | Reconcile active state to retryable queued state and issue a new attempt ID. |
| Response arrives after retry/delete | Attempt/state guard discards it. |
| Provider fields become stale | Refresh through provider policy before presenting them as current; show last checked and fall back to stale/unknown while confirmed identity remains stable. |
| Density calculation fails | Fall back to grouped confirmed pins; never hide all saved places. |

## Security and privacy

### Trust boundaries

1. Share-extension input is untrusted text/URL.
2. App Group defaults are a handoff queue, not authoritative storage.
3. Backend request evidence is user-controlled input.
4. TikTok oEmbed and place providers are external, rate-limited systems.
5. Provider responses are untrusted data constrained by schemas and display limits.

### Controls

- HTTPS only; exact hostname allowlists with normalized IDNA/Unicode handling.
- Bounded redirect count; validate each hop and final destination.
- Reject URL credentials, fragments when canonicalizing, nonstandard ports, and IP literals.
- Resolve and block loopback, private, link-local, multicast, reserved, and metadata-service address
  ranges; pin/verify resolved addresses across connect to mitigate DNS rebinding.
- Backend egress allowlists for TikTok oEmbed and selected place-provider origins.
- Request/response size limits, short timeouts, circuit breakers, and per-user/device rate limits.
- Provider keys stored in server secret management, never app configuration or logs.
- Strict decoding and output length limits before data reaches UI/SwiftData.
- No raw screenshot upload in MVP.
- No raw video upload or social-media downloading in MVP.
- Bounded temporary media staging with explicit cleanup on success, cancellation, failure, and
  expiry.
- Evidence and precise source URLs excluded from analytics and routine logs.
- Backend should remain stateless for source/evidence payloads unless a later retention policy is
  explicitly approved.
- Deleting a local source deletes its evidence/candidates and updates density immediately.

Before production, a targeted independent security review must verify URL canonicalization, redirect
handling, DNS/IP enforcement, secrets, rate limiting, deletion, logging, and provider-policy
compliance.

## Meaningful alternatives

| Alternative | Benefit | Cost/risk | Decision |
|---|---|---|---|
| Keep manual place entry only | Lowest platform and backend risk | Does not fulfill turning social saves into ready map data | Retain only as fallback |
| TikTok-only first release | Fastest compliant automation | Leaves Instagram users with no guided flow | Use as rollout slice, not final MVP |
| Fully on-device with `MKLocalSearch` | No backend or external key | Weak text interpretation/control, inconsistent evaluation, no secure optional providers | Useful prototype, not target architecture |
| Apple-only resolver | Native correction and fewer vendors | Coverage/ranking uncertainty and provider lock-in | Benchmark as fallback |
| Google primary + Apple manual correction | Strong broad matching plus native escape hatch | Server key, billing, attribution, retention compliance | Recommended pending benchmark/approval |
| Foursquare primary | Strong venue-specific matching | Coverage/cost must be validated | Benchmark challenger |
| Hosted LLM first | Better handling of messy captions | New paid service, privacy/cost/nondeterminism, prompt-injection surface | Defer behind interpreter interface |
| Async backend jobs | Handles provider refreshes and batch evaluation | Adds worker/queue operations before the synchronous flow is measured | Defer; reserve a Railway worker process when a measured workload requires it |
| Supabase Auth/Postgres plus custom service | Fast mobile auth, generated APIs, and realtime primitives | Splits auth, migrations, policies, logs, and data ownership across Supabase and Django before sync/accounts are in scope | Reject for this feature; reconsider in a future sync/collaboration brief |
| Rails modular monolith | Strong conventions and built-in Active Job | Requires separate admin selection and is less aligned with planned Python evaluation/text tooling | Django selected |
| Apify TikTok/Instagram actors | Can return captions, transcripts, metadata, and media from a shared URL with little engineering | Unauthorized-scraping policy risk; TikTok actor is community-maintained; Instagram actor advertises downloaded media without a documented metadata-only control; run outputs are stored in Apify datasets; legal responsibility remains with the customer | Do not integrate; keep provider ports flexible and require separate legal/privacy approval before any future internal spike |
| Gradient heatmap | Familiar density metaphor | Conflicts with style guide and implies false continuity | Reject |
| H3/geospatial library | Mature stable cells | Adds a dependency requiring approval | Start with versioned Web Mercator grid |
| Community-wide density | Stronger "what is happening" signal | Product drift plus accounts, consent, k-anonymity, moderation, abuse prevention | Separate future brief and feature flag |

## Architecture decisions requiring build-kickoff approval

- Django API toolkit/package set, Python version, and Railway deployment/CI details.
- Production place provider and any paid plan.
- Whether deterministic evidence interpretation meets the labeled quality gate.
- Any hosted LLM, analytics SDK, geospatial dependency, or cloud media processor.
- Any Apify or other social-scraper experiment, including its legal basis, actor permissions,
  dataset deletion/retention, cost ceiling, and proof that media download is disabled.
- Exact provider fields retained and their refresh/deletion policy.
- Public-client abuse protection before live rollout; no shared secret may be embedded in the app.

## Requirement traceability

This architecture covers [SPE-1 through SPE-20](01-brief.md#requirements). The implementation Plan
must provide one verification row per requirement/failure case, including:

- client and server URL-policy fixtures;
- interrupted import and stale-response tests;
- Vision OCR boundary tests without screenshot upload;
- SwiftData relaunch/offline tests;
- provider contract and failure mapping tests;
- candidate top-three evaluation;
- confirmation-before-map integration tests;
- deterministic density fixtures and accessible map behavior.
