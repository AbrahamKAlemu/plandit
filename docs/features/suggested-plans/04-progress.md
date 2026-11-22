# Suggested plans: progress

Documents: [brief](01-brief.md) · [brief reviews](01-brief_reviews.md) ·
[architecture](02-architecture.md) · [plan](03-plan.md)

## Summary

Approved November 21, 2026. Slice A is in review as #44. B and C are being built.

## Attention needed

- Abraham merges each slice's PR (merging is blocked for Claude).
- #44 (slice A) is stacked on #41: merge #41 first.

## Phases

| Phase | Status |
|---|---|
| Clarify | Done: source = own saves, placement = empty Today (Abraham, November 21). |
| Brief, architecture, plan | Drafted November 21. |
| Persona review | Done November 21: 4 approve, Andre's 2 must_fix fixed (SP-19, SP-20). [01-brief_reviews.md](01-brief_reviews.md) |
| Human approval | Approved November 21 with the recommended answers. |
| Build (A, B, C) | A done (#44). B and C in progress. |
| Verify, ship, learn | Not started. |

## Tasks and evidence

- Slice A, `feat/suggestion-used-event`, #44 (base `fix/rls-all-tables`):
  - Tests: `354 passed, 6 subtests passed` on a local Postgres. `makemigrations --check` is clean; ruff is clean.
  - Migration `core/0009` only changes choices (sqlmigrate prints a no-op).
  - Fixed the date-based `test_event_is_stored`, which was failing on main.
  - Independent review (reviewer, high): no must-fix findings.

## Decisions and events

- November 21: the plan's `UsageEventTests` is the iOS test, so slice B updates it with the enum case. Slice A added a backend test for the exact event-name list instead.
- November 21: Abraham approved the dossier and the recommended answers to Q-1 to Q-3.
- November 21: Abraham picked "their own saves" and "the empty Today".
- November 21: v1 doesn't read location; "close" means stops close to each other (brief Q-1).
- November 21: suggestions are computed on the phone and never stored or synced.
