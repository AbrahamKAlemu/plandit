# App polish for 1.0.1: progress

## Summary

Dossier approved by Abraham on November 18, 2026. The same day he added the team's design
feedback (App Design Feedback.pdf), the category images and a new app icon; those are being
added to the brief as D requirements.

## Attention needed

- PR #28 and #29 merged on November 18. A, D and E were built on 413d299 and need merging onto the new main.
- Two walkthrough findings belong to Eldad's planner work and aren't in scope: the planner put a
  "late lunch" after dinner (walkthrough shot 42; a GitHub issue for Eldad once approved), and
  Today's times disagree by 1 to 3 minutes (W-17 rechecks after #28, or moves to 1.0.2).
- Website and App Store wording change with slice A (plan, Rollout).
- Existing sync risk, found in the slice E review and not caused by this work: an existing account
  whose first sign-in on a new phone can't reach the server gets an empty offline seed. That seed
  is pushed once the server answers, and `PUT /api/me/snapshot/` doesn't check versions, so it
  can replace the real cloud copy. A Render cold start longer than the 30 s fetch timeout is
  enough. It needs its own issue (not opened yet).
- `MapAndBudgetFlowTests.testReorderingTheStopsAhead` fails on 413d299 too, so none of these
  slices caused it. Its cause isn't settled: the time of day (the sample stop is "Done or
  underway" after about 2:30 PM) or how iOS 27.2 labels the reorder control. Slice C looks at it.

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
| Build A (bar, Profile, logo) | Built; xhigh review done (no account or data-loss bugs); fixing 7 findings | `feature/polish-bar-profile`, 5 commits; 261 unit tests, UI 30/31 (the reorder test, which also fails on the base) |
| Build E (tutorial) | Built, reviewed (pass); fixing review findings | `feature/polish-tutorial`; review: interrupted tutorial, pre-account saves, AX5, iPad width, double-tap |
| Build C (sheets and Today) | In progress | `feature/polish-today`, from main e81d1d0 |
| Build B (share and processing) | Waiting | A and D merged onto main |
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
