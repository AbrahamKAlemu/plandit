# Suggested plans: progress

Documents: [brief](01-brief.md) · [brief reviews](01-brief_reviews.md) ·
[architecture](02-architecture.md) · [plan](03-plan.md)

## Summary

Approved November 21, 2026. All three slices are in review: A #44, B #48, C #49.

## Attention needed

- Abraham merges each slice's PR (merging is blocked for Claude).
- #44 (slice A) is stacked on #41: merge #41 first.
- #48 (B) is stacked on #40, and #49 (C) on #48. #44 must deploy before the app version with B ships.
- Not verified on a device: SP-17 (under 50 ms on an iPhone 12), and VoiceOver in Accessibility Inspector.

## Phases

| Phase | Status |
|---|---|
| Clarify | Done: source = own saves, placement = empty Today (Abraham, November 21). |
| Brief, architecture, plan | Drafted November 21. |
| Persona review | Done November 21: 4 approve, Andre's 2 must_fix fixed (SP-19, SP-20). [01-brief_reviews.md](01-brief_reviews.md) |
| Human approval | Approved November 21 with the recommended answers. |
| Build (A, B, C) | Done: A #44, B #48, C #49. |
| Verify, ship, learn | Not started. |

## Tasks and evidence

- Slice A, `feat/suggestion-used-event`, #44 (base `fix/rls-all-tables`):
  - Tests: `354 passed, 6 subtests passed` on a local Postgres. `makemigrations --check` is clean; ruff is clean.
  - Migration `core/0009` only changes choices (sqlmigrate prints a no-op).
  - Fixed the date-based `test_event_is_stored`, which was failing on main.
  - Independent review (reviewer, high): no must-fix findings.

- Slice B, `feat/suggested-plans-today`, #48 (base `polish/launch-profile-sheet`):
  - Unit lane: 477 passed on the tip (f84274f). The full lane on C's tip before the last store-only fix
    passed 474 unit + 78 UI tests. A first full run under heavy load failed 2 UI tests that passed alone.
  - Review (high): 4 must-fix (rating dates, places done today, Change it's start, the stale message),
    all fixed. The second review found that a synced copy from an earlier day wiped today's done list.
    The first fix compared dates as text, and a third review caught that it could freeze. Now only a
    plan for the real current day is recorded. A final check of that hunk found nothing.
  - Copy matches SP-18, which the personas reviewed with the brief.
- Slice C, `feat/suggested-plans-change-it`, #49 (base `feat/suggested-plans-today`):
  - Unit lane: 478 passed on the tip (0724768). Change it starts at the card's own first stop.

## Decisions and events

- November 21: places done today are kept in a file on the phone, never synced, and only a plan for the
  real current day updates them.
- November 21: a bare "11/15" is a date only on temporary saves; "10/10", "9/10" and "24/7" never are
  without a year.
- November 21: the plan's `UsageEventTests` is the iOS test, so slice B updates it with the enum case. Slice A added a backend test for the exact event-name list instead.
- November 21: Abraham approved the dossier and the recommended answers to Q-1 to Q-3.
- November 21: Abraham picked "their own saves" and "the empty Today".
- November 21: v1 doesn't read location; "close" means stops close to each other (brief Q-1).
- November 21: suggestions are computed on the phone and never stored or synced.
