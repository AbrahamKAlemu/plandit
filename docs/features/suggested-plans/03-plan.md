# Suggested plans: plan

Status: draft for approval, November 21, 2026. Brief: [01-brief.md](01-brief.md). Architecture:
[02-architecture.md](02-architecture.md).

## Slices

Each slice is its own PR, and the app works after each one lands.

| Slice | Outcome | Depends on | Lands safely because |
|---|---|---|---|
| A. Event (backend) | The server accepts `suggestion_used`, and metrics count it. | none | No app sends it yet. |
| B. Suggestions in Today (iOS) | Cards in the empty Today; "Use this plan" works. | A deployed | It only changes the empty state when there are 2+ plannable saves. |
| C. Change it (iOS) | "Change it" opens the planner with the picks. | B | It adds an argument with a default; "Plan a day" doesn't change. |

Integration owner: the main thread (orchestrator). B and C touch `TodaySheet`, so they're built in
order, not in parallel.

## Workstream contracts

### A. Event

- Add `suggestion_used` in the same places as `place_saved`: the model choices plus a migration,
  the serializer, `openapi.yaml`, `backend/README.md` and `metrics.py` (`suggestions_used`).
- Update `UsageEventTests` to the new exact list.
- Run tests only on a local Postgres, never `backend/.env`. The migration only changes choices
  (no SQL), so the row level security test from #41 isn't affected.

### B. Suggestions in Today

- `PlanSuggester` and `PlanSuggestion` in `Services/PlanSuggester.swift`, written test-first in
  `PlanSuggesterTests` (rows SP-1 to SP-9 and SP-17).
- Move `defaultStart()` to a shared `PlanDefaults`; `PlanBuilderSheet` calls it from there.
- `PlanditStore.suggestions`, `refreshSuggestions()` with the cache key from the architecture, and
  `useSuggestion(_:) -> UseResult` (`.applied` or `.stale`).
- `SuggestionCard` plus the empty state in `TodaySheet`. The empty state with saves becomes a
  scroll view with the heading, the cards and "Plan a day"; the "no saves" state doesn't change.
- `.suggestionUsed` in the app's events.
- Accessibility identifiers: `today-suggestions`, `suggestion-card-<index>`,
  `suggestion-use-<index>`, `suggestion-change-<index>`.
- UI test `SuggestedPlansFlowTests` with a DEBUG seed (launch argument `-seedSuggestions`) of 5
  places in two clusters with fixed hours and prices, and `planStart` fixed to 14:00.

### C. Change it

- `AppRouter.startPlanning(picks:start:budget:)` with defaults; `PlanBuilderSheet.setUp()` reads
  and clears them once.
- Extend `SuggestedPlansFlowTests`.

## Verification

| Requirement | Acceptance/failure case | Command/observation | Owner | Evidence/status |
|---|---|---|---|---|
| SP-1 | Only saved, mappable posts appear; a post without a place never does. | `PlanSuggesterTests.testUsesOnlyMappableSaves` | B builder | not run |
| SP-2 | 1 plannable save gives 0 suggestions; 2 far-apart saves give 0; 2 close saves give 1 with 2 stops; groups never exceed 4. | `PlanSuggesterTests.testGroupSizeBounds` | B builder | not run |
| SP-3 | Every suggestion's `outcome.cost` is at or under the budget, including fares; a budget of $0 with paid places gives none. | `PlanSuggesterTests.testRespectsBudget` | B builder | not run |
| SP-4 | Every suggestion starts at the default start and ends by start + 4 h. | `PlanSuggesterTests.testFitsWindow` | B builder | not run |
| SP-5 | A place "open until 3 PM" with a 2 PM start isn't planned past 3 PM; one that closed at 1 PM isn't suggested. | `PlanSuggesterTests.testSkipsClosed` | B builder | not run |
| SP-6 | With "Walk only", every leg is a walk; with transit, no leg is longer than one subway ride; places 5 miles apart are never paired. | `PlanSuggesterTests.testStopsStayClose` | B builder | not run |
| SP-7 | At most 3 suggestions; no stop appears in two. | `PlanSuggesterTests.testDistinctStops` | B builder | not run |
| SP-8 | Shuffled input gives identical output; the same 15-minute slot gives the same output. | `PlanSuggesterTests.testDeterministic` | B builder | not run |
| SP-9 | Places in today's plan or checked off today aren't suggested. | `PlanSuggesterTests.testExcludesToday` | B builder | not run |
| SP-19 | A caption "Pop-up Nov 15–17" saved Nov 10 isn't suggested on Nov 21; "until Dec 1" still is. "Sample sale this weekend" with no date is suggested 13 days after saving and not 15. Both can still be picked in the planner. | `SaveFreshnessTests`; `PlanSuggesterTests.testSkipsProbablyOver` | B builder | not run |
| SP-20 | Of two equal plans, the newer saves come first; a plan with a 120-day-old save ranks below any plan without one. | `PlanSuggesterTests.testRecency` | B builder | not run |
| SP-10 | Tapping "Use this plan" gives Today the card's stops, order and total; Undo empties Today again. | `SuggestedPlansFlowTests.testUseThisPlan`; `PlanditStoreTests.testUseSuggestionMatchesPreview` | B builder | not run |
| SP-11 | When a card goes stale (a stop closed after it was shown), the tap doesn't change Today; the cards refresh and "It's later now, so these plans changed." shows. | `PlanditStoreTests.testUseSuggestionStale` | B builder | not run |
| SP-12 | "Change it" opens the planner with the same picks in order, same start and budget; cancelling leaves Today empty. | `SuggestedPlansFlowTests.testChangeIt` | C builder | not run |
| SP-13 | "Plan a day" is visible below the cards and opens an empty planner; with no saves, "Paste a link" shows as before. | `EmptyTodayFlowTests` (updated), `SuggestedPlansFlowTests` | B builder | not run |
| SP-14 | No new colors, fonts or icons in the diff. | Reviewer reads the diff | B reviewer | not run |
| SP-15 | VoiceOver reads a card as one element with the label format in the brief and two custom actions. | Accessibility Inspector on the simulator; UI test checks the label | B builder | not run |
| SP-16 | At AX5 text size, cards stack and scroll and nothing is cut off; at the lowest sheet height, cards are hidden. | Simulator screenshots at AX5 and at peek height | B builder | not run |
| SP-17 | 300 saves: suggestions in under 50 ms on an iPhone 12-class device, or computed off the main thread. | `PlanSuggesterTests.testPerformance300` (`measure`), plus one device run | B builder | not run |
| SP-18 | Persona agents return no `must_fix` on the copy; no word from AGENTS.md's list appears. | Persona run before build ([01-brief_reviews.md](01-brief_reviews.md)); grep the diff | Orchestrator | not run |
| Analytics | `suggestion_used` is accepted and counted; unknown names still get 400. | `pytest tests/test_events.py`, `UsageEventTests`, metrics test | A builder | not run |

Full lanes before each PR: `cd backend && pytest` (local Postgres) and `ruff`; the iOS unit and UI
tests on the iPhone 17 Pro simulator, as AGENTS.md says. Before a TestFlight upload, also an
iOS 18 run.

## Testing checkpoint

No independent test-planning review was selected: the logic is a pure function with a table of
cases above, and the UI change is one screen. The completion reviewer (below) checks the table.

## Review owners

- Code review per slice: `reviewer` (high).
- Completion review before the last PR: an independent `reviewer` checks the integrated app
  against every row above and walks the changed flow once on the simulator.

## Human approval

Waiting for Abraham. Silence isn't approval. Open questions Q-1 to Q-3 are in the brief.

## Rollout and final checks

1. Merge A; Render deploys; `POST /api/me/events/` with `suggestion_used` returns 201 in
   production (one request from a test account).
2. Merge B and C; TestFlight build; check on a device with the demo account's 9 saves that cards
   appear and "Use this plan" works. Then reset the demo account.
3. Ship with the next App Store version. What's New: one line, run past the personas.
4. After a week, read `suggestions_used` against `plan_built` in the class metrics.
5. Update AGENTS.md "What we learned" in the cleanup step.
