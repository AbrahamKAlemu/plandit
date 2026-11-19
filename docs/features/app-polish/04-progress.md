# App polish for 1.0.1: progress

## Summary

Abraham approved the dossier on November 18, 2026, and the same day added the team's design
feedback (App Design Feedback.pdf), the category images and a new app icon as D requirements.
All five slices are built, reviewed and fixed. They go out as six stacked PRs, each based on the
one before:

| PR | Branch | What |
|---|---|---|
| 1 | `app-polish/docs` | This dossier |
| 2 | `app-polish/a-bar-profile` | Four-item bar, Profile with Appearance and Account, icon and logo |
| 3 | `app-polish/d-saved-list` | Saved: category tiles, Filter and Sort, slim rows |
| 4 | `app-polish/e-tutorial` | First-run tutorial |
| 5 | `app-polish/c-today` | Today's times, rides, sheet headers, empty Today |
| 6 | `app-polish/b-share` | Share flow, this status, and the 1.0.1 version bump |

Merge them in that order, deleting each merged branch so GitHub moves the next PR onto `main`.

## Attention needed

- After the stack merges: the website PR on Jaden's repo ("Profile → Account → Delete account" on
  privacy, terms and support; the new logo; the privacy wording below), and the App Store 1.0.1
  description and review notes ("in your Profile"). Abraham approves before submitting.
- plandit.app/privacy says only the text found in a video is used to search Apple Maps. The app also
  keeps that text as the post's caption, which syncs. True since 1.0, and covered by "Other User
  Content" in the App Store answers. Fix the policy wording in the website PR.
- Device checks on TestFlight before merging: share a TikTok, an Instagram post and a Photos video;
  feel the haptic when a place is added; VoiceOver keeps the share sheet open until Done or Undo.
  The iOS 18 run (AGENTS.md) can't be done on Xcode 27, which has no iOS 18 simulator; use a phone
  on iOS 18 if one is available.
- Existing sync risk, found in the slice E review and not caused by this work: an existing account
  whose first sign-in on a new phone can't reach the server gets an empty offline seed. That seed
  is pushed once the server answers, and `PUT /api/me/snapshot/` doesn't check versions, so it
  can replace the real cloud copy. A Render cold start longer than the 30 s fetch timeout is
  enough. It needs its own issue (not opened yet; needs Abraham's yes).
- Planner findings for Eldad, out of scope (one GitHub issue, once Abraham says yes): the planner
  put a "late lunch" after dinner (walkthrough shot 42), and `startRestFromNow` on a day that runs
  past midnight leaves times that a Time sheet changes again when opened (`DayPlan.shiftStops`
  applies the evening rule from each stop's own date).

## Deferred to 1.0.2

- Fix a shared video's post in place (slice B review finding 12).
- From the final review: retry a video lookup that fails offline, and say so; mark the launch
  conversion of 1.0 shares for sync; call an Instagram `/p/` post "this post", not "this Reel"; keep
  the share queue per account.
- The Home tab of lists (feedback Change 3).
- From the screen walk: post screens (Places found, could-not-place, a saved post) have no solid header
  behind the back button; on the SE at half height, Today's Directions and Saved's Paste a link start
  under the bar (both scroll into view); at AccessibilityXL, Saved rows cut their second line, the
  email breaks mid-word, and Try again and Paste a link don't grow; three unpicked shares all read
  as their first suggestion; "In plan" is pale in the planner; Plan's label sits 2 pt high; the travel
  sheet's footer is clipped at half height.

## Final checks (November 18)

- Final independent review of the whole stack at xhigh: one must-fix (two share problems claimed a
  TikTok profile link wasn't from TikTok and offered an add-by-name that doesn't exist). Fixed in
  7d5139a, with the test covering all four problems again.
- Persona round 5 on the share and travel wording: five approvals, no must_fix. Their wording for the
  ride wait, the rest-of-day titles and the "can't save videos" line is in.
- Full suite on d17cb7e: 413 unit tests, 67 of 68 UI tests (the one failure was a timing race in the
  empty-Today test's setup, which passed alone; fixed in 362491e), PlanditShare builds. After the
  final fixes: 414 unit tests, ShareFlowTests 9 of 9, EmptyTodayFlowTests 2 of 2.
- Screen walk (iPhone 17 Pro, SE, iPad, dark mode, AccessibilityXL; 212 screenshots): three must-fix,
  fixed in the commits after this note. The bar rode up over the keyboard and covered Search on the
  could-not-place screen; How it works still said to tap "Save to Plandit"; Today's main button and
  date were cut off at the largest text sizes. Not driven: the bus travel sheet and the drive's
  pickup line (each needs a trip state the sample day doesn't have); unit tests cover both.

## Documents

- [Brief](01-brief.md) and [brief reviews](01-brief_reviews.md)
- [Architecture](02-architecture.md)
- [Plan and verification](03-plan.md)

## Phase status

| Phase | Status | Evidence |
|---|---|---|
| Clarify | Done | Three decisions on November 18 (brief, Questions) |
| Walkthrough | Done | 91 screenshots, November 18 (scratchpad, not committed) |
| Brief | Draft complete | Persona round 1: five approvals, no must_fix |
| Architecture | Draft complete | |
| Plan | Draft complete | |
| Persona round 2 (W rows) | Done | Five approvals, no must_fix |
| Human approval | Done | Abraham, November 18, in chat |
| Persona round 3 (D rows) | Done | Five approvals; Marcus's must_fix (Skip ends the tutorial) fixed |
| Build D (Saved list) | Built, reviewed, fixes re-reviewed | `feature/polish-saved-list`; 261 unit tests, targeted UI 16/16. W-9 proved by screenshot 09 (the test only checks the label) |
| Build A (bar, Profile, logo) | Built; xhigh review done (no account or data-loss bugs); 7 findings fixed. The last fix commits are checked in the final review | `feature/polish-bar-profile`; 268 unit tests, ProfileFlowTests 10/10 |
| Build E (tutorial) | Built, reviewed, fixes re-reviewed | `feature/polish-tutorial`; 278 unit tests; FirstRunTutorialTests 19, TutorialFlowTests 12, twice each |
| Integration (docs, A, D, E on main) | Done | 319 unit tests; UI 55/56 (the reorder test, fixed in C); share extension builds |
| Build C (sheets and Today) | Built, reviewed twice, all findings fixed | `app-polish/c-today` 046cde3; 349 unit tests, EmptyToday and TodaySummary UI tests pass |
| Build B (share and processing) | Built, reviewed at xhigh, fixed (finding 12 moved to 1.0.2) | `app-polish/b-share`; 414 unit tests; ShareFlowTests 9 of 9 |
| Final review and screen walk | Done | See Final checks above |
| Release | PRs open; TestFlight build next | Six stacked PRs; 1.0.1 build from `app-polish/b-share` |

## Decisions and events

| Date | Event |
|---|---|
| Nov 18 | Abraham chose: separate Plan button; save instantly and finish in the app; ask the user to pick when unsure. |
| Nov 18 | Walkthrough of 91 screens in light, dark and iPad. 17 W requirements added. |
| Nov 18 | Persona round 1 on the brief: Sofia, Marcus, Andre, Grace and Amara approve; suggestions dispositioned in [brief reviews](01-brief_reviews.md). |
| Nov 18 | Persona round 2 on W-1 to W-17: five approvals, no must_fix. W-2, W-16, W-17 and PRO-2 updated. |
| Nov 18 | Abraham approved the dossier. |
| Nov 18 | Abraham asked for the design feedback PDF, the "Images for the app" category images and the new glossy "P" icon (app icon and in-app logo) to be built too. |
| Nov 18 | Abraham: keep Today for 1.0.1; the Home tab of lists (feedback Change 3) waits for 1.0.2, when the lists arrive and the planner-vs-feed rule is settled. |
| Nov 18 | Persona round 3 on D-1 to D-8: approvals; Marcus's must_fix fixed in D-1; "Added" became "In plan". |
| Nov 18 | Slice D reviewed; five findings fixed and re-reviewed. |
| Nov 18 | Slice E reviewed: D-1 passes. Decided: a tutorial that was started but not finished shows again at the next launch (it ends only with Skip or the last page). |
| Nov 18 | The team asked for SVG Repo icons instead of the watercolor category pictures. SVG Repo blocked automated downloads, so the same Phosphor duotone icons (MIT) came from Phosphor's own package. Built in slice D (daed2a8). The glossy P stays as the app icon and logo. |
| Nov 18 | PR #28 and #29 merged; slice C started from main. |
| Nov 18 | Slice A reviewed at xhigh: account actions safe. Fixing: past-plan rounding, stat alignment and word breaks, Profile map framing, case-insensitive neighborhoods, dead code, README. Empty Today at half height moved to slice C. Recorded, not fixed: a 1.0 phone drops `fares` from synced past plans (last writer wins); the iPad mini zoom on a selected pin. |
| Nov 18 | Kept the 80 km cap on the map. A, D and E restacked onto main; the undo bar from #29 sits just above the new tab bar. Slice B started. |
| Nov 18 | Slice C stacked on E; its tab-bar spacer dropped because A's bar already sits below the sheet. Second review of C: travel sheet keeps the plan's line and fare, travel changes clear a pending undo, bus trips show as planned. |
| Nov 18 | Slice B built. Persona round 4 on its new copy: five approvals, no must_fix; error wording simplified from their suggestions. |
| Nov 18 | Persona round 5: five approvals, no must_fix. Final review at xhigh: one must-fix (share problem wording), fixed. Abraham asked to cut review rounds to one final review and one screen walk. |
| Nov 18 | Bumped to 1.0.1. The six stacked PRs opened for Abraham to merge. |
| Nov 19 | After the first 1.0.1 build, Abraham asked for Plan to look like the other bar items (replaces D-2's emerald pill) and for the bar to float as an island with no band behind it. Built in 5a5d944 to 3adaf7a; new pushed screens need `.clearsFloatingBars()`. Abraham's account was seeded for device testing (27 saved posts, 6 past plans). |
| Nov 19 | On Abraham's phone, with Button Shapes on, iOS drew a second shape around Share, Filter and Sort. They now use the plain style, so their own outline is the button's shape. Edit uses the same outlined control as Filter and Sort. Text-only buttons still get the system shape. |
