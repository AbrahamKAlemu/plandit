# App polish for 1.0.1: progress

## Summary

Dossier approved by Abraham on November 18, 2026. The same day he added the team's design
feedback (App Design Feedback.pdf), the category images and a new app icon; those are being
added to the brief as D requirements.

## Attention needed

- PR #28 and #29 merged on November 18. The docs, A, D and E are restacked on the new main (e81d1d0)
  as `app-polish/docs`, `app-polish/a-bar-profile`, `app-polish/d-saved-list` and
  `app-polish/e-tutorial`, then `app-polish/c-today` and `app-polish/b-share`: one PR each, stacked in
  that order. Nothing is pushed yet.
- Two walkthrough findings belong to Eldad's planner work and aren't in scope: the planner put a
  "late lunch" after dinner (walkthrough shot 42; a GitHub issue for Eldad once approved), and
  Today's times disagree by 1 to 3 minutes (W-17 rechecks after #28, or moves to 1.0.2).
- Website and App Store wording change with slice A (plan, Rollout).
- plandit.app/privacy (Jaden's repo) says only the text found in a video is used to search Apple Maps.
  The app also keeps that text as the post's caption, which syncs. True since 1.0; covered by
  "Other User Content" in the App Store answers. Fix the policy wording in the website PR.
- Existing sync risk, found in the slice E review and not caused by this work: an existing account
  whose first sign-in on a new phone can't reach the server gets an empty offline seed. That seed
  is pushed once the server answers, and `PUT /api/me/snapshot/` doesn't check versions, so it
  can replace the real cloud copy. A Render cold start longer than the 30 s fetch timeout is
  enough. It needs its own issue (not opened yet).
- `MapAndBudgetFlowTests.testReorderingTheStopsAhead` fails on main too. Cause: #29 put the stop's
  number and time into the reorder control's accessibility label, so the test's exact match broke.
  Slice C fixes the test; it passes on `app-polish/c-today`.
- More planner findings for Eldad's issue (with the late lunch): `startRestFromNow` on a day that runs
  past midnight leaves times that a Time sheet changes again when opened (`DayPlan.shiftStops` applies
  the evening rule from each stop's own date).

## Resume here (paused November 18, evening, for an account switch)

Branches (local only, nothing pushed), stacked in this order on main e81d1d0:

| PR | Branch | Head |
|---|---|---|
| 1 docs | `app-polish/docs` | 3687b8c (then cherry-pick 92200c8's successors from `feature/app-polish`: af627d3, f11fdeb and this note) |
| 2 bar and Profile | `app-polish/a-bar-profile` | 8037c1d |
| 3 Saved | `app-polish/d-saved-list` | 79d2764 |
| 4 tutorial | `app-polish/e-tutorial` | 7153a98 |
| 5 Today | `app-polish/c-today` | 046cde3 (reviewed twice, done) |
| 6 share | `app-polish/b-share` | d17cb7e (on 046cde3) |

Slice B review fixes committed on d17cb7e: findings 1 to 11, 13, 14 and the persona wording. Finding 12
(fix a shared video post in place) moved to 1.0.2. On d17cb7e the 413 unit tests pass; the UI tests and the PlanditShare build haven't run yet
(rerun with the scratchpad's `b-tools/full.sh`, or the README's test command on a `git archive` export).

Left, in order (Abraham approved push, PRs and TestFlight on November 18):

1. Full suite on d17cb7e from a `git archive` export (unit, UI, PlanditShare build).
2. Persona agents on B's new strings: "Plandit already has this one. You can remove it in Saved.",
   "Street, neighborhood or city", "Name, like Levain Bakery", "This can take a minute or two.", and
   the reworded share problems.
3. One final independent review of the whole stack (`git diff e81d1d0..app-polish/b-share`) at xhigh,
   alongside one walk of the changed screens (iPhone 17 Pro, SE, iPad, dark, large text). Fix must-fix only.
4. Cherry-pick the docs commits onto `app-polish/docs` and rebase the stack.
5. Push the 6 branches and open 6 stacked PRs (each based on the one before).
6. Bump to 1.0.1 as the last commit of the share PR, then `ios/scripts/testflight.sh` from the top of
   the stack so Abraham can test sharing, the haptic and VoiceOver on a phone before merging.

Deferred to 1.0.2: finding 12 above; the drive and bus Eldad findings; the sync data-loss issue
(needs Abraham's yes to open); the GitHub issue for Eldad (needs a yes).

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
| Build B (share and processing) | Built; persona round 4 passed; xhigh review: 2 must-fix (extension privacy manifest, PRC-3 retry never fired in production) and 12 smaller; fixing | `app-polish/b-share` 1372ff4 on c-today f74693a; 381 unit and 67 UI tests, 0 failures |
| Reviews and flow walk | Not started | |
| Release | Not started | |

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
