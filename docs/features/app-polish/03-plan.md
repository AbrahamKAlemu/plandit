# App polish for 1.0.1: plan

Requirements: [01-brief.md](01-brief.md). Design: [02-architecture.md](02-architecture.md).

## Slices

Three pull requests. Each one leaves the app working and passes the full iOS test command from
AGENTS.md before it opens.

| Slice | Outcome | Requirements | Depends on | Conflicts with |
|---|---|---|---|---|
| **A. Bar, Profile and logo** | Four-item bar; Profile per the design draft with Appearance and Account; nothing hidden under the bar; auth and iPad fixes; new app icon and logo | NAV-2–4, PRO-2–4, W-1, W-3–6, W-8, D-2, D-6, D-7, D-8 | `main` | None with PR #28 |
| **D. Saved list** | Category pictures, Filter and Sort, slimmer rows with + and Added | D-3–5, PRC-5, W-7, W-9, W-10 | `main` | B (`SavedSheet`); B builds on it |
| **E. First-run tutorial** | Three pages for brand-new accounts | D-1 | `main` | None |
| **B. Share and processing** | One-step share for links and videos; clearer finding-the-place flow; post screen fixes | SHR-1–6, PRC-1–4, PRC-6–8, W-11–14 | A, D, and PR #28 merged or rebased onto | PR #28 (`PlanditStore`, `SavedPostDetailView`) |
| **C. Sheets and Today** | Solid sheet headers; rides instead of "0.0 mi"; Today's times agree | W-15–17 | PR #28 merged | PR #28 (`TodaySheet`) |

A, D and E are built at the same time in separate worktrees, each on its own simulator.
B starts after A and D merge. `ios/Plandit.xcodeproj/project.pbxproj` is generated: on a conflict, take either side
and rerun `xcodegen generate`.

Integration owner: the main thread (orchestrator) merges each worker's branch into the slice
branch, runs the full suite, and owns rebases onto PR #28.

## Workstream contracts

Every builder reads AGENTS.md first, uses only existing design tokens and components
(`Color.*`, `Space.*`, `Radius.*`, Manrope, `Icon(Lucide)`), follows the
[test-first loop](../../../.claude/skills/feature-forge/references/build-loop.md) for behavior,
runs `xcodegen generate` after adding or removing files, never commits secrets, and doesn't touch
`backend/`. If something the brief doesn't decide comes up, the builder stops and asks the
orchestrator.

### A. Bar and Profile

- **Owned files:** `ios/Plandit/App/Navigation.swift`, `App/RootView.swift`,
  `DesignSystem/PlanditTabBar.swift`, `Features/Profile/*`, `Features/Auth/EmailAuthScreen.swift`,
  `Features/Auth/WelcomeScreen.swift`, `Features/Map/MapViewport.swift`,
  `Models/UserProfile.swift` (stats only), `Features/Auth/AuthFlowView.swift` (splash logo only),
  `PlanditShare/ShareView.swift` (logo asset only), `BrandArt` in `Shared/DesignSystem/Icon.swift`,
  `Shared/SharedAssets.xcassets/Brand`, `Resources/Assets.xcassets` (AppIcon, skyline), the
  affected UI tests, and new files under `Features/Profile/`.
- **W-1 first.** Find why pushed screens and sheet scroll views ignore the bar's
  `safeAreaInset`, and fix it once in `SheetContainer`, not per screen.
- **Authority:** move the Account UI, but don't change `AccountModel` or any sign-in or deletion
  logic.
- **Review:** an independent reviewer at xhigh effort, because the change moves the
  account-deletion entry point.

### D. Saved list

- **Owned files:** `Features/Saved/SavedSheet.swift` (and new files beside it), the `Lucide` enum
  in `Shared/DesignSystem/Icon.swift` and `Shared/SharedAssets.xcassets/Icons` (star,
  chevron-down), `Resources/Assets.xcassets/Categories`, and the matching tests. Read-only use of
  `Pricing.swift` and `PlanditStore.addToToday`.
- **Authority:** no model or sync change. Status logic stays where it is; only its words change.
- **Review:** an independent reviewer at high effort.

### E. First-run tutorial

- **Owned files:** new `Features/Onboarding/*`, `App/PlanditApp.swift` (`AccountGate` only),
  `Services/Sync/AccountSession.swift` (expose the new-account signal only), and the matching
  tests.
- **Authority:** no change to sign-in, sign-up, tokens, Keychain or sync decisions.
- **Review:** an independent reviewer at xhigh effort, because it touches the account bootstrap.

### B. Share and processing

- **Owned files:** `ios/PlanditShare/*`, `ios/Shared/Sharing/*` (including the new
  `ShareIntake.swift` and the moved `TemporaryMediaStore`), `Services/PlanditStore.swift` (share
  ingest, extraction retry, launch recovery only), `Services/VideoEvidenceExtractor.swift`,
  `Features/Saved/*`, `App/PlanditApp.swift` (ingest routing), `project.yml` (share activation
  rule only), and the matching tests.
- **Authority:** no change to the confidence rule, the backend endpoint, or the sync snapshot
  format. `IncomingShare` must still decode 1.0's queued entries.
- **Review:** an independent reviewer at high effort (app-group file handling and privacy).

### C. Sheets and Today

- **Owned files:** `Features/Today/*` (except logic changed by PR #28 unless W-17 needs it),
  `Features/Plan/PlanBuilderSheet.swift`, and shared header styling in `DesignSystem/`.
- **W-17:** first re-measure on `main` after PR #28 merges. If the times already agree, record it
  and stop.
- **Review:** an independent reviewer at high effort.

## Verification

"Unit" and "UI" mean XCTest in `PlanditTests` and `PlanditUITests`, run with the AGENTS.md
command. "Shot" means a simulator screenshot compared with the November 18 walkthrough
(`scratchpad/walkthrough/`, numbers in parentheses).

| Requirement | Acceptance / failure case | Command / observation | Owner | Evidence / status |
|---|---|---|---|---|
| NAV-1 | Replaced by D-2 | | | n/a |
| NAV-2 | `-startTab settings` opens Profile; no "Settings" tab button exists | UI launch test | A builder | Not started |
| NAV-3 | VoiceOver labels; targets ≥ 44 pt; no clipping at the largest standard text size on iPhone 17e | UI frame assertions; shot at `UIContentSizeCategoryExtraExtraExtraLarge` | A builder | Not started |
| NAV-4 | Same bar in the iPad panel | Shot on iPad mini | A builder | Not started |
| PRO-1 | Replaced by D-6 | | | n/a |
| PRO-2 | No "Coming soon" text anywhere; Notifications gone; recent plan rows show per-person cost, budget mark and amount ("$22 under") when recorded, no chevron, no navigation | UI: search for "Coming soon" across tabs; unit test for row text | A builder | Not started |
| PRO-3 | Sign out and Delete account call the same `AccountModel` methods; dialog unchanged except Cancel | Existing auth unit tests pass unchanged; UI opens the dialog from Profile (82) | A builder, xhigh reviewer | Not started |
| PRO-4 | Appearance switches live from Profile | Existing `AppearanceFlowTests`, updated path | A builder | Not started |
| W-1 | Last element fully above the bar on stop detail, Profile, Today large, empty Today at medium | UI: element `frame.maxY` ≤ bar `frame.minY` after scrolling (16b, 72, 14, 31) | A builder | Not started |
| W-2 | No longer applies (D-6 drops these numbers) | | | n/a |
| W-3 | Hint only on Create account | UI on both modes (03) | A builder | Not started |
| W-4 | iPad Welcome width ≤ 440 pt; Saved and Profile maps show Manhattan | Shots on iPad mini (A2–A4) | A builder | Not started |
| W-5 | Dialog has Cancel, and Cancel does nothing | UI | A builder | Not started |
| W-6 | Name screen says it saves on its own | Shot (73) | A builder | Not started |
| W-7 | Saved tip "Save from TikTok and Instagram"; Profile row "How it works", "Saving places from TikTok and Instagram" | UI text assertion | D builder (tip), A builder (row) | Not started |
| W-8 | Appearance row icon isn't the gear | Shot | A builder | Not started |
| SHR-1 | Supported link → queued without a tap; confirmation shows the "next time you open it" line; closes after about 2 s | Unit: `ShareIntake` with `NSItemProvider` fixtures; manual on device: TikTok and Instagram | B builder; device check by Abraham | Not started |
| SHR-2 | Undo removes the queue entry and the video file | Unit | B builder | Not started |
| SHR-3 | Movie provider → file staged in `TemporaryMedia`, queued by name; over 250 MB or not a movie → error, nothing queued | Unit; manual on device: share from Photos | B builder; device check by Abraham | Not started |
| SHR-4 | Unsupported, no link, bad video → message naming "a TikTok, an Instagram post or Reel, or a video", Close, nothing queued | Unit | B builder | Not started |
| SHR-5 | No auto-close while VoiceOver runs | Unit on the close policy; manual with VoiceOver | B builder | Not started |
| SHR-6 | Same link twice → one post | Unit (existing dedupe plus intake) | B builder | Not started |
| PRC-1 | One share opens the post; several open Saved; peek rises to medium; no shares → no jump; several look up at once | UI with a pre-seeded inbox launch argument; unit for concurrency | B builder | Not started |
| PRC-2 | Source shown while finding; "Still looking" after 8 s | UI with a slow fake extractor | B builder | Not started |
| PRC-3 | One automatic retry on a transient error, then "We couldn't find a place" | Unit with a fake extractor that fails once, and one that fails twice | B builder | Not started |
| PRC-4 | Shared video success → normal paths; failure → post stays in `needsEvidence` | Unit with a fake video extractor | B builder | Not started |
| PRC-5 | Status words exactly as listed | Unit on the status text | D builder | Not started |
| PRC-6 | Auto-add only on a unique exact-address match | Existing extractor tests pass unchanged | B builder | Not started |
| PRC-7 | Success haptic and "Add to today's plan" after an add | UI | B builder | Not started |
| PRC-8 | Relaunch with a `.video` post in `processing` → `needsEvidence`, not "couldn't read this source" | Unit | B builder | Not started |
| W-9 | Long names with a status keep at least the first 20 characters | UI or shot (52) | D builder | Not started |
| W-10 | Date wording rules wherever a saved date still shows | Unit on the formatter | D builder | Not started |
| W-11 | Add a link: Cancel at top, placeholder visible, Save above the keyboard | UI with the keyboard up (64) | B builder | Not started |
| W-12 | Search field starts empty; one title; no link in captions | UI on a bare-link post (60, 61) | B builder | Not started |
| W-13 | Copy matches the platform; Remove at the bottom | Shot (66) | B builder | Not started |
| W-14 | Both video buttons share one style | Shot | B builder | Not started |
| W-15 | Headers opaque while scrolled | Shots (25, 42, 46) | C builder | Not started |
| W-16 | Day with no walking shows rides by kind ("2 subway rides") | Unit or UI with a subway-only plan (47) | C builder | Not started |
| W-17 | Stop start ≥ earliest arrival; same minutes in timeline and travel sheet. If #28 hasn't merged when 1.0.1 is cut, recorded as open for 1.0.2 | Re-measure after PR #28; unit if code changes (17, 22) | C builder | Not started |
| D-1 | Brand-new account (seeded) sees 3 pages once; Skip on page 1 or the last Continue lands on the map in one tap; an account with server or local data never sees it; relaunch doesn't repeat it | Unit on the decision; UI with `-showTutorial`; shots of the 3 pages, light and dark | E builder, xhigh reviewer | Not started |
| D-2 | Four items in order Today, Saved, Plan, Profile; Plan opens the planner; VoiceOver "Plan a day"; 44 pt targets | UI | A builder | Not started |
| D-3 | Only categories present; tap filters; tap again clears; shopping shows under Others | Unit on `SavedListQuery`; UI | D builder | Not started |
| D-4 | Free only hides places that cost money; Oldest reverses order; both combine with a category | Unit on `SavedListQuery` | D builder | Not started |
| D-5 | Row reads "Category · Neighborhood" (+ "· Free"); + adds to today in one tap and becomes "In plan"; with no plan today it starts one or opens the planner with the place picked; posts without a place show their status | Unit on row text; UI tap + | D builder | Not started |
| D-6 | Section order; 3 numbers; Neighborhoods counts distinct neighborhoods of visited places; tapping the header opens Name | UI identifiers in order; unit on `UserStats` | A builder | Not started |
| D-7 | AppIcon is 1024×1024 with no alpha; the build installs; home screen shows the new icon | `sips -g hasAlpha`; simulator home screen shot | A builder | Not started |
| D-8 | New mark on splash, Welcome, Profile footer and share sheet | Shots | A builder | Not started |
| All | Full suite green; one independent walk of changed flows; persona gate on new copy | AGENTS.md iOS command; reviewer walk; persona agents | Orchestrator, reviewers | Not started |

## Testing checkpoint

No separate testing reviewer: the table covers each requirement's failure case, and every slice
gets an independent code and completion review before its PR.

## Human approval

Needed from Abraham before any app code changes: the brief, architecture and this plan
together. Recorded in [04-progress.md](04-progress.md).

## Rollout and final checks

1. Each slice merges after its review, with Abraham's merge approval (or merged by Abraham).
2. After A merges: open a PR on Jaden's website repo changing "Settings → Account → Delete
   account" to "Profile → Account → Delete account" on privacy, terms and support, and mirror it
   in this repo's `website/`. Jaden merges.
3. After all three merge: bump to 1.0.1, run the tests on an iOS 18 device or simulator (AGENTS.md
   lesson), upload with `ios/scripts/testflight.sh`, and test on Abraham's iPhone: share a TikTok,
   an Instagram post and a Photos video.
4. In App Store Connect for 1.0.1: update the description ("in your Profile") and the App Review
   notes ("Profile > Delete account"). Abraham approves before submitting.
5. Update AGENTS.md "What we learned" and close this dossier.
