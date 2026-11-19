# App polish for 1.0.1: architecture

Requirements are in [01-brief.md](01-brief.md); acceptance and proof are in the
[Plan verification table](03-plan.md#verification). This document says where each change lives
and what can go wrong.

## Summary

Everything is iOS-only. No backend, database, sync-format or auth change. The design feedback
additions are listed at the end of Affected components.

1. **Navigation.** `AppTab` loses `.settings`. `PlanditTabBar` becomes a three-tab group plus a
   separate Plan button. Settings' two sections (Appearance, Account) move into `ProfileSheet`.
2. **Share extension.** The extension saves as soon as it has a supported link or a video, then
   shows a short confirmation with Undo. Videos are copied into the app group's existing
   `TemporaryMedia` folder and queued by file name. The app still does all the finding.
3. **In-app processing.** `PlanditStore.ingestPendingShares` learns video shares. Extraction
   retries once on a transient error. The post screen shows the post's source while it waits,
   and a slow-server message after 8 s.

## Existing structure (reconnaissance, November 18)

| Area | Where | Today |
|---|---|---|
| Tabs | `ios/Plandit/App/Navigation.swift` (`AppTab`, `SheetRouter`) | `today, saved, profile, settings`; `-startTab` launch argument picks the first tab |
| Bar | `ios/Plandit/DesignSystem/PlanditTabBar.swift` | Five slots; the emerald Plan button is inserted before Profile; selected pill slides with `matchedGeometryEffect` |
| Shell | `ios/Plandit/App/RootView.swift` | Map + always-on sheet; switches on every `AppTab` case (map framing, selection, content) |
| Profile | `ios/Plandit/Features/Profile/ProfileSheet.swift` | Header, Activity, Recent plans (each row → `PlaceholderScreen` "Coming soon"), Preferences (incl. Notifications → "Coming soon"), footer |
| Settings | `ios/Plandit/Features/Profile/SettingsScreen.swift` | Display → Appearance; Account → signed in as, Sign out, Delete account (confirmation dialog) |
| Share extension | `ios/PlanditShare/ShareViewController.swift`, `ShareView.swift` | Reads a URL (or the first link in shared text), validates with `SupportedSocialURL`, shows an explanation and a "Save to Plandit" button, then enqueues |
| Hand-off | `ios/Shared/Sharing/ShareInbox.swift` | `IncomingShare { id, url, sharedText, receivedAt }` JSON array in app-group `UserDefaults`; deduped by URL |
| Ingest | `PlanditApp.swift` (`scenePhase == .active`) → `PlanditStore.ingestPendingShares()` | Saves each link (`save(url:sharedText:)`), acknowledges it, opens the post (one) or Saved (several) |
| Extraction | `PlanditStore.extract(_:)` → `FixturePlaceExtractor` | Backend `v1/social-evidence` (60 s timeout) with TikTok oEmbed fallback, then MapKit search; one unique exact-address match auto-saves, otherwise `needsConfirmation` |
| Video | `VideoEvidenceExtractor.swift` (`TemporaryMediaStore`, on-device OCR + speech) | Staged into app-group `TemporaryMedia/` (250 MB cap), read, then deleted; files older than 24 h removed at launch |
| Statuses | `ExtractionStatus` in `Models/SavedPost.swift` | processing, needsEvidence, needsConfirmation, ready, needsReview, failed |

Posts left in `processing` restart extraction on launch (`PlanditStore.init`). For a video post
that re-runs URL extraction on its `plandit-video://` placeholder URL and fails as "We couldn't
read this source". That bug matters more once videos arrive by share, so this work fixes it.

Open PR #28 (Eldad) changes `TodaySheet`, `SavedPostDetailView` and `PlanditStore`. This work
starts from `main` after #28 merges, or rebases onto it.

## Affected components

| Component | Change |
|---|---|
| `Navigation.swift` | Remove `.settings`. `launchTab` maps the old `settings` value to `.profile` so existing launch arguments keep working. |
| `PlanditTabBar.swift` | `HStack { tab group (Today, Saved, Profile) ; Plan button }`. Same tokens as today: `surface`, `border`, `emeraldTint` pill, `emerald` Plan with `onEmerald` content. The Plan button keeps the `plan-button` identifier and the "Plan a day" label. |
| `RootView.swift` | Drop the `.settings` cases. When the router opens a post or Saved because of a share, raise the sheet from peek to medium. |
| `ProfileSheet.swift` | New order: header (adds the signed-in email), Activity, Recent plans (inline rows, no navigation), Preferences (Name, Default budget, Home base, Getting around), App (Appearance, Saving from TikTok and Instagram), Account (signed in as, Sign out, Delete account + confirmation + inline error), footer. |
| `SettingsScreen.swift` | Deleted. `AppearanceScreen` and the account row move to `Features/Profile/` (new file `AppearanceScreen.swift`, account rows inside `ProfileSheet.swift` or `AccountSection.swift`). `xcodegen generate` after adding/removing files. |
| `PlaceholderScreen` | Deleted once nothing uses it. |
| `Shared/Sharing/ShareInbox.swift` | `IncomingShare` gains `videoFileName: String?`, and `url` becomes optional. Old queued entries (url only) still decode. `enqueue` returns the stored share. `remove(_:)` deletes a share and its video file (Undo). Links still dedupe by URL. |
| `Shared/Sharing/ShareIntake.swift` (new) | The extension's attachment reading, moved out of `ShareViewController` so unit tests can drive it with `NSItemProvider`s. Order: movie file → URL → first link in text. Returns `.link(URL, sharedText)`, `.video(stagedFileName)`, `.unsupported`, `.noLink` or `.videoProblem(message)`. |
| `Shared/Sharing/TemporaryMediaStore` | Moved from `Plandit/Services/VideoEvidenceExtractor.swift` to `Shared/` so the extension can stage a video with the same 250 MB rule and folder. Cleanup is by age only: a staged video is deleted after 24 hours even if a queued share still names it (that share then asks for the video again). It runs when the extension loads and whenever the app becomes active, signed in or not. A video being read is moved to a `Reading/` folder first so cleanup can't delete it mid-read. |
| `PlanditShare/ShareViewController.swift`, `ShareView.swift` | States: `saving` → `saved(summary)` → closes after about 2 s (not while VoiceOver runs) or on Done; Undo calls `ShareInbox.remove` and closes; `unsupported` / `noLink` / `videoProblem` show a message and Close. |
| `project.yml` | Share extension activation rule adds `NSExtensionActivationSupportsMovieWithMaxCount: 1`. |
| `PlanditStore.swift` | `ingestPendingShares` handles video shares through a new `importSharedVideo(fileURL:)`: creates a `.video` post in `processing`, acknowledges the share, reads the video in the background, and on failure keeps the post as `needsEvidence` (instead of deleting it like `saveVideo` does). `extract(_:)` retries once after about 2 s for errors other than `DevelopmentSocialEvidenceError`. Launch-time restart skips `.video` posts and marks them `needsEvidence` ("Share the video again or add the place's name"). |
| `SavedPostDetailView.swift` | Processing state shows `SourceCard` (platform, creator, caption, thumbnail when known) above a progress line; after 8 s it adds the slow-server line. Status copy updated. |
| `SavedSheet.swift` | Status words per the brief (PRC-5). |
| Website (`website/` here and Jaden's live repo) | "Settings → Account → Delete account" becomes "Profile → Account → Delete account" in privacy, terms and support. Not code in this repo's app; tracked as a rollout step. |

### Design feedback additions (D requirements)

| Component | Change |
|---|---|
| `PlanditTabBar.swift`, `Navigation.swift` | Four items in one bar: Today, Saved, Plan (emerald pill, still `plan-button`), Profile. Replaces the separate-button layout above. |
| `Features/Saved/SavedSheet.swift` | Category tile row (Phosphor duotone SVGs, template images, in `Resources/Assets.xcassets/Categories`), Filter and Sort menus, slimmer `SavedPostRow` with Added / + / status. A pure `SavedListQuery` (category, free only, sort) holds the rules so unit tests cover them. "Others" groups `shopping` and any future category; `PlaceCategory` itself is unchanged. |
| `Models/Pricing.swift` | Read-only use: free means `plannedCost == 0` (user's cost, else the stated or typical price; parks are 0). |
| `Shared/DesignSystem/Icon.swift`, `SharedAssets.xcassets/Icons` | Adds Lucide `star` and `chevron-down` (same source and license as the other Lucide icons). |
| `ProfileSheet.swift`, `UserProfile.swift` | D-6 order; skyline image (`profile-skyline`); `UserStats` keeps plans completed, neighborhoods (distinct `visited[].neighborhood`) and places saved, and drops walked, average, under budget and streak. |
| `AppIcon.appiconset` | New full-bleed 1024 icon; the dark variant is removed so dark mode uses the same icon. |
| `BrandArt` (`Shared/DesignSystem/Icon.swift`), `SharedAssets.xcassets/Brand` | New `mark-square` art (the glossy P with rounded corners). Splash, Welcome and Profile's footer show it beside "Plandit" set in Manrope instead of the old lockup images; the share sheet uses it at its current size. |
| `Features/Onboarding/` (new), `PlanditApp.swift` (`AccountGate`), `AccountSession.swift` | `AccountSession` exposes whether bootstrap seeded a brand-new account (`SyncDecision.seedAndPush` / `.seedOffline`). If so, and the tutorial hasn't been finished for that user id on this phone (`UserDefaults` key per user id), `AccountGate` shows `TutorialView` before `PlanditRoot`. No change to sign-in, tokens or sync. Debug launch argument `-showTutorial` forces it for UI tests. |

## Flows

**Share a link.** TikTok → Share → Plandit → extension reads the URL → `SupportedSocialURL`
canonicalizes it → `ShareInbox.enqueue` → "Saved to Plandit" (with creator and caption when the
share included text) → closes after about 2 s. Later: Plandit becomes active →
`ingestPendingShares` → `save(url:)` → post in `processing` → router opens it, sheet at medium or
higher → extraction (backend, then MapKit) → auto-added (exact address) or "Pick the place" (up to
three cards) or "Couldn't find it" (Try again, add details, use a video).

**Share a video.** Photos → Share → Plandit → extension copies the movie into
`TemporaryMedia/<uuid>.<ext>` (rejects over 250 MB or not a movie) → enqueues with
`videoFileName` → confirmation. Later: ingest → `importSharedVideo` → on-device OCR and speech →
same result paths; on failure the post stays in `needsEvidence`. The file is deleted after it's
read (existing behavior) or by the 24 h cleanup.

**Undo.** The confirmation's Undo removes the queued share and deletes its video file. Nothing
reaches the app.

**Delete account (moved).** Profile → Account → Delete account → confirmation dialog →
`AccountModel.deleteAccount()`: unchanged, including the Apple re-authorization and revocation.

## Alternatives considered

| Option | Decision |
|---|---|
| Find the place inside the share extension | Rejected for 1.0.1 (user decision, November 18). It needs the Supabase session in a shared Keychain access group, a migration for existing sessions (risk of signing people out), and token refresh in two processes, where refresh-token rotation can invalidate a session. Render's free plan can also hold the share sheet open for up to a minute. Revisit after a paid Render plan and a shared-session design. |
| Always add the best guess | Rejected (user decision, November 18). Wrong matches have happened (Chubby Bowls → Playa Bowls). Confidence rule unchanged. |
| Settings behind a gear button in Profile's header | Not chosen. It hides Delete account one level deeper. Inline "Account" keeps it one scroll away and gives the documented path "Profile → Account → Delete account". |
| Keep the Save button in the share sheet | Not chosen. It costs a tap on every share; Undo covers mistakes. |
| Process video in the extension | Rejected: extensions have tight memory limits, and OCR plus speech over a long video can exceed them. |

## Failure modes

| Failure | Handling |
|---|---|
| App group container missing (unsigned simulator build) | Links still queue through the `UserDefaults` fallback; the extension says it can't save videos in this build instead of writing to a folder the app can't read. |
| Extension killed while copying a video | The queue entry is written only after the copy finishes; a partial file is removed by the 24 h cleanup. |
| Video too large, not a movie, or unreadable | Extension shows the existing `VideoEvidenceError` message and queues nothing. |
| Shared video file gone when the app ingests (cleanup or storage) | Post is created in `needsEvidence` with "Share the video again or add the place's name". |
| App quits while a video post is processing | On next launch the post moves to `needsEvidence` instead of re-running URL extraction. |
| Render asleep (30–60 s) | Progress line plus "Still looking" after 8 s; one automatic retry on a transient failure; then "Couldn't find it" with Try again. |
| Same link shared twice | One post (existing dedupe by canonical URL); the confirmation still reads "Saved". |
| `ingestPendingShares` runs twice (scene phase flaps) | Each share is acknowledged after its post is saved, so it's handled once. |
| Old queued entries from 1.0 on upgrade | Still decode (`url` present, no `videoFileName`). |

## Security and privacy

- No new data leaves the phone. Videos stay on the device, as in 1.0's Privacy Policy.
- No change to auth, tokens, Keychain, or the backend's trust boundary.
- The extension never reads the session. It only writes to the app group.
- The App Store "App Privacy" answers and the Privacy Policy stay true. Only the deletion path's
  wording changes.

## Links

- Requirements and question history: [01-brief.md](01-brief.md)
- Slices and the verification table: [03-plan.md](03-plan.md)
