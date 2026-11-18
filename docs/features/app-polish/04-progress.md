# App polish for 1.0.1: progress

## Summary

Dossier approved by Abraham on November 18, 2026. The same day he added the team's design
feedback (App Design Feedback.pdf), the category images and a new app icon; those are being
added to the brief as D requirements.

## Attention needed

- Slices B and C overlap Eldad's open PR #28. They start after it merges, or rebase onto it.
- Two walkthrough findings belong to Eldad's planner work and aren't in scope: the planner put a
  "late lunch" after dinner (walkthrough shot 42; a GitHub issue for Eldad once approved), and
  Today's times disagree by 1 to 3 minutes (W-17 rechecks after #28, or moves to 1.0.2).
- Website and App Store wording change with slice A (plan, Rollout).
- Existing sync risk, found in the slice E review and not caused by this work: an existing account
  whose first sign-in on a new phone can't reach the server gets an empty offline seed. That seed
  is pushed once the server answers, and `PUT /api/me/snapshot/` doesn't check versions, so it
  can replace the real cloud copy. A Render cold start longer than the 30 s fetch timeout is
  enough. It needs its own issue (not opened yet).
- `MapAndBudgetFlowTests.testReorderingTheStopsAhead` fails after about 2:30 PM local time: the
  sample stop is then "Done or underway". It fails on 413d299 too (came in with #27). Slice C
  fixes it with #28's clock.

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
| Build E (tutorial) | Built, reviewed (pass); fixing review findings | `feature/polish-tutorial`; review: interrupted tutorial, pre-account saves, AX5, iPad width, double-tap |
| Build A (bar, Profile, logo) | In progress | `feature/polish-bar-profile` |
| Build B, C | Waiting | A and D merged; PR #28 |
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
