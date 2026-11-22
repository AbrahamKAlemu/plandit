# Suggested plans: architecture

Status: approved by Abraham, November 21, 2026. Brief: [01-brief.md](01-brief.md). Verification:
[03-plan.md](03-plan.md#verification).

## Summary

A new pure type, `PlanSuggester`, turns the store's plannable posts plus the planning inputs into
at most three `DayPlanner.Outcome`s. It runs the existing `DayPlanner` on small groups of nearby
places and scores the results. `TodaySheet`'s empty state shows them. "Use this plan" calls the
existing `PlanditStore.buildPlan(postIDs:start:budget:mode:end:)` with `.replace`; "Change it" opens
the planner with a preselection. Nothing new is stored or synced. The backend only adds one event
name.

## Existing structure (reconnaissance, November 21, main at f4167f5)

- `ios/Plandit/Services/DayPlanner.swift:106`: `DayPlanner` is a synchronous value type.
  `plan(Request) -> Outcome`. `Request` has `candidates`, `start`, `budget`, `anchor`,
  `alreadySpent` and `dayEnd`. It searches every order exactly up to `exactSearchLimit` (7)
  candidates and reports skips as `closed`, `overBudget` or `outOfTime`. `Outcome` exposes `stops`,
  `legs`, `skipped`, `cost`, `travelMinutes`, `walkingMiles` and `end`.
- Opening hours: `closingTime(on:)` (DayPlanner.swift:79) only reads "until X". Anything else
  counts as open, so SP-5 can only be as good as that parser.
- Travel between stops is estimated from coordinates (`TravelLeg.estimate`, Models/DayPlan.swift:162):
  walk up to 1.2 miles, otherwise subway at $2.90, limited by `TravelPreference`
  (`walkOnly` or `walkAndTransit`).
- `ios/Plandit/Services/PlanditStore.swift`:
  - `plannablePosts` (:1032) are saved posts with a place.
  - `previewPlan(postIDs:start:budget:mode:end:)` (:1050) plans without changing anything.
  - `buildPlan(...)` (:1056) applies it. `.replace` records an undo ("Made a new plan") and emits
    `.planBuilt` when there are stops (:1084).
  - `travelPreference` (:1029) comes from `profile.travelModes`.
- `UserProfile` has `defaultBudget` and `travelModes`; `homeBase` is free text. There is no
  distance setting and no stored location.
- `ios/Plandit/Features/Today/TodaySheet.swift:27-42` shows the empty state inside a
  `ViewThatFits` (with icon, without icon, scrolling) marked `.hiddenWhenSheetCollapsed()`.
  `emptyToday(showsIcon:)` (:134-179) shows "Paste a link" with no saves, else "Plan a day"
  (`today-plan-a-day`) calling `router.startPlanning()`.
- `PlanBuilderSheet` keeps its picks in `@State picked: [UUID]`, with `defaultStart()` (:225) and a
  budget set up from the profile in `setUp()`. `AppRouter.startPlanning()` (App/Navigation.swift:75)
  only sets `isPlanning = true`; there's no way to pass picks in.
- Events: the app's `events?(.planBuilt)` closure posts to `POST /api/me/events/`. The backend
  allows `plan_built`, `link_saved` and `place_saved`. The list is repeated in the model's choices,
  the serializer, a migration, `openapi.yaml`, `backend/README.md` and `metrics.py`;
  `UsageEventTests` asserts the exact list.
- Tests: `EmptyTodayFlowTests` (UI) checks the empty state and that "Plan a day" sits above the
  tab bar. `DayPlannerTests` cover the planner.

## Affected components

| Component | Change |
|---|---|
| `Services/PlanSuggester.swift` (new) | Pure suggestion logic (below). |
| `PlanditStore` | `suggestions: [PlanSuggestion]`, recomputed on the triggers in the brief; `useSuggestion(_:)` |
| `TodaySheet` | Empty state with saves shows suggestion cards above "Plan a day". |
| `Features/Today/SuggestionCard.swift` (new) | The card, built from existing components. |
| `AppRouter`, `PlanBuilderSheet` | `startPlanning(picks: [UUID] = [], start:budget:)`; the sheet reads the preselection once in `setUp()`. |
| `PlanditEvent` (iOS) | `.suggestionUsed` |
| Backend events | `suggestion_used` added to the allowlist everywhere it's listed, plus a migration for the choices and a `suggestions_used` count in metrics. |

### PlanSuggester

```swift
struct PlanSuggestion: Identifiable, Equatable {
    var id: String            // the post ids joined, stable across recomputes
    var postIDs: [UUID]       // in plan order
    var outcome: DayPlanner.Outcome
    var title: String         // "Chelsea" or "Chelsea and Flatiron"
}

struct PlanSuggester {
    var planner: DayPlanner
    var maxSuggestions = 3
    var groupSize = 2...4
    func suggestions(posts: [SavedPost], excluding: Set<UUID>, start: Date,
                     budget: Double, end: Date) -> [PlanSuggestion]
}
```

1. **Candidates:** plannable posts not in `excluding` (today's stops and today's checked-off
   places, SP-9) and not probably over (SP-19). If there are more than 40, keep the 40 saved most
   recently, so the work is bounded.
   - `SaveFreshness.isProbablyOver(post, now:)` finds dates in the caption with Foundation's
     `NSDataDetector` (on the phone, no library). It treats a date with no year as the next one
     after `savedAt`.
   - It checks the caption and tags against a short list of temporary words for the 14-day rule.
   - The result is cached per post id and caption.
2. **Groups:** for each candidate as a seed, take it plus its nearest neighbors whose trip from the
   seed is a walk under 1.2 miles (or one subway ride when transit is allowed), up to 4 places.
   Remove duplicate groups.
3. **Plan:** run `planner.plan` with `start`, `budget` and `dayEnd = end` on each group. Keep
   outcomes with at least 2 stops whose legs all satisfy SP-6.
4. **Score:** a lexicographic key, compared in order:
   1. any save older than 90 days (no before yes, SP-20);
   2. then a weighted sum of:
      - stops (2 to 4, more is better up to 3);
      - category mix (+ when food and non-food are both present);
      - recency (the average age of the saves in days, newer is better, SP-20);
      - travel minutes (less is better);
      - money left (more is better).

   Ties go to the lower joined post id, so results don't depend on dictionary order (SP-8). The
   weights are constants in `PlanSuggester` with a test per term.
5. **Pick:** walk the sorted list and take outcomes whose stops don't overlap the ones already
   taken, until 3 (SP-7).

Cost: at most 40 groups × 4! orders each, about 1,000 small plans, well within SP-17. If the
iPhone 12 measurement says otherwise, the store runs it in a detached task and publishes the result
on the main actor.

### Inputs and the time slot

- `start = PlanBuilderSheet.defaultStart()` (the planner's default, so "Change it" lands on the
  same start). The function moves to `PlanDefaults` so both places share it.
- `end = start + 4 hours` (SP-4), `budget = profile.defaultBudget` (SP-3).
- The 15-minute slot is `floor(start / 15 min)`. The store caches suggestions by (slot, saves
  revision, budget, travel setting, today's stop ids).

## Flows

**Show:** Today becomes empty, or a trigger fires → `store.refreshSuggestions()` → `TodaySheet`
reads `store.suggestions` → 0 cards: the current empty state; 1 to 3 cards: heading, cards, then
"Plan a day".

**Use this plan:** tap → `store.useSuggestion(s)` → recompute the preview with the same inputs →
same stops and order as `s`: `buildPlan(postIDs: s.postIDs, …, mode: .replace, end:)`, send
`.suggestionUsed` → Today shows the plan and the map shows the route. Different: replace the cards
and show "It's later now, so these plans changed." (SP-11).

**Change it:** tap → `router.startPlanning(picks: s.postIDs, start:, budget:)` → planner opens
with them picked → "Build my plan" works as now.

## Alternatives

- **Server-side suggestions.** The server has every snapshot, but the planner is Swift and runs on
  the phone. Porting it would make two planners that drift apart. Rejected.
- **Suggest by neighborhood name.** Group saves whose `neighborhood` string matches. Simple, but
  the strings are inconsistent ("Chelsea" and "West Chelsea") and neighbors across a border would
  never pair. Distance between coordinates is already what the planner uses. Rejected as the main
  method; the name is still used for the card title.
- **Show suggestions in a new tab or on the map.** The brief puts them in the empty Today, the one
  place the student looks when there's no plan (Abraham's choice).
- **Use the phone's location** for "near you". Deferred (brief Q-1).

## Failure modes

| Case | Behavior |
|---|---|
| Fewer than 2 plannable places | No cards; current empty state. |
| Every group is over budget, closed or too far apart | No cards; current empty state. No error message, since nothing is wrong. |
| A card goes stale (closing time passes, slot moves) | SP-11: refresh, message, no silent change. |
| The student edits their saves while the cards are showing | Recompute; cards may change. Accepted. |
| Late at night, everything closes | No cards. The planner's existing "can run late" behavior doesn't apply, because suggestions stop at start + 4 hours. |
| Sync pulls a new snapshot with a plan for today | Today isn't empty any more, so the cards disappear. |
| The event is sent before the backend knows it | Slice order prevents it. If it happens, the server answers 400 and the app drops the event as it does for any failed event. |

## Security and privacy

Nothing leaves the phone except the `suggestion_used` event name and time, which follows the
existing events policy. No new data is stored, no location is read, nothing is shared. No privacy
policy or App Privacy change is needed for v1. Q-1 (location) would need both.
