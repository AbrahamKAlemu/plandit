# Suggested plans: brief

Status: approved by Abraham, November 21, 2026. Owner: Abraham.

## Context

Today is empty for most of the day. When it is, it says "Nothing planned yet" and offers one
button, "Plan a day". That opens the planner, where the student picks places one by one, sets a
start time, an end time and a budget, then taps "Build my plan". That's at least five decisions
before they see a plan.

Students with saves (Sofia, Andre, Amara, Grace) already told Plandit where they want to go. The
app can build two or three plans from those saves on its own and show them where the empty state
is now, so the next step is one tap: "Use this plan".

Who it's for: students with at least two saved places that are on the map. Marcus (no saves)
still sees "Paste a link"; this feature doesn't help him until he saves something.

**Doing nothing:** the planner keeps working. But the empty Today asks for work before it shows
anything, and a "real user" in the class metrics is someone who built a plan. Fewer decisions
before the first plan is the most direct way to raise that number.

**Product guardrail:** these are plans made only from the student's own saves. Plandit never
suggests a place they didn't save. It stays a planner, not a discovery feed.

## Scope

In:

1. Up to three ready-made plans in the empty Today, built on the phone from the student's saved
   places.
2. Each plan fits the student's budget, starts at the planner's usual start time, keeps stops
   close to each other, and leaves out places that are closed.
3. "Use this plan" makes it today's plan in one tap. "Change it" opens the planner with those
   places already picked.
4. A count of how often a suggestion is used (one new event).

Out (not in this feature):

- Places the student hasn't saved, trending places, or anything from other users.
- Reading the phone's location. "Close" means close to each other, not close to the student
  (see Q-1).
- Notifications ("You have a free afternoon…").
- Suggestions for another day, or when Today already has a plan.
- Group suggestions (see the group-plans dossier).
- Any new server storage. Suggestions are worked out on the phone each time and never synced.

## Solution outline

When Today has no stops and the student has at least two places on the map, the empty state shows
a short list under the heading **"Plans from your saves"**. Each card shows:

- a name from where the stops are, for example "Chelsea" or "Chelsea and Flatiron";
- the stop names, in order (up to three, then "+1 more"), with "check hours" after a stop whose
  hours the app can't read;
- one line of facts: "3 stops · 2:30–6:15 PM · $24 each with subway". The cost is per person and
  includes fares, as the planner already counts them. With no fares it says "$24 each, all
  walking";
- two buttons: **Use this plan** and **Change it**.

Under the cards, the existing "Plan a day" button stays for students who want to pick themselves.

The plans come from the same planner that builds plans today (DayPlanner), so a suggestion and a
plan built by hand follow the same rules: opening hours, budget, travel time and travel cost.
Plandit tries small groups of saved places that are near each other, plans each group, and keeps
the best two or three that don't share a stop. "Best" favors plans built from recent saves, with
two to four stops, a mix of food and something else, less travel and more money left over. A save
that's probably over (a pop-up whose date has passed, or a "this weekend only" post saved weeks
ago) is left out.

The suggestions are recomputed when the student's saves, budget or travel setting change, when
Today becomes empty, when the app comes back to the foreground and every 15 minutes, because the
start time moves and places close. Between those, the cards stay the same, so they don't reshuffle
while someone is reading them.

## Requirements

### What's suggested

- **SP-1** Suggestions use only the student's saved places that are on the map. No other source.
- **SP-2** Each suggestion has 2 to 4 stops. Fewer than two plannable places, or no group that
  makes a plan of at least two stops, means no cards; the empty state looks as it does now.
- **SP-3** A suggestion's total cost (stops plus travel) is at or under the student's default
  budget in Profile.
- **SP-4** A suggestion starts at the planner's default start time and ends within 4 hours of it.
- **SP-5** No stop is planned at a time when its known hours say it's closed. Places with no
  hours, or hours the app can't read, are allowed, as they are in the planner now.
- **SP-6** Stops in a suggestion are close to each other: every trip between them is a walk of
  1.2 miles or less, or one subway ride, as the student's travel setting allows. "Walk only" means
  walking trips only.
- **SP-7** Up to three suggestions are shown, and no two share a stop.
- **SP-8** The same saves, settings and 15-minute time slot always give the same suggestions in
  the same order.
- **SP-9** A place already in today's plan, or checked off today, isn't suggested.
- **SP-19** A save that's probably over isn't suggested. It can still be planned by hand.
  - If its caption names a date (read on the phone with Apple's date detection) and the latest such
    date has passed, it's over.
  - If its caption or tags say it's temporary ("pop-up", "sample sale", "limited time", "this
    weekend", "last day", "one day only") and it has no date, it's suggested only for 14 days after
    it was saved.
- **SP-20** Recent saves rank higher. Between two otherwise equal plans, the one whose saves are
  newer comes first. Saves older than 90 days rank below every newer option.

### Using one

- **SP-10** "Use this plan" makes exactly the plan on the card today's plan: same stops, order,
  times and cost. It records the same undo step as building a plan by hand ("Made a new plan").
- **SP-11** If the card is out of date when tapped (a stop has closed since, or the time slot
  moved), Plandit doesn't apply a different plan silently. It refreshes the cards and says "It's
  later now, so these plans changed."
- **SP-12** "Change it" opens the planner with that suggestion's places already picked, in that
  order, with the same start time and budget. Nothing changes in Today until "Build my plan".
- **SP-13** "Plan a day" stays below the cards and works as it does now.

### Look and access

- **SP-14** Cards use the existing design system (cards, metadata labels, primary and secondary
  buttons). No new colors, fonts or icons until the style guide lands.
- **SP-15** VoiceOver reads each card as one element ("Chelsea. 3 stops, 2:30 to 6:15 PM, $24
  each with subway. Joe's Pizza, The High Line, Chelsea Market.") with "Use this plan" and "Change
  it" as its actions.
- **SP-16** At the largest text sizes the cards stack and scroll; no text is cut off. At the
  sheet's lowest height the cards are hidden like the rest of Today's content.
- **SP-17** Working out suggestions never blocks scrolling or typing: under 50 ms on an iPhone 12
  with 300 saved places, or done off the main thread.

### Copy

- **SP-18** Heading "Plans from your saves", buttons "Use this plan" and "Change it", the cost
  "$24 each with subway" or "$24 each, all walking", "check hours", and the stale message "It's
  later now, so these plans changed." The persona agents review this text before build; any
  `must_fix` blocks it. None of the words AGENTS.md rules out for headlines ("discover", "explore",
  "itinerary", "curated" and the rest) appear anywhere in the feature.

## Analytics and logging

One new event, `suggestion_used`, sent when "Use this plan" makes a plan. It has no properties,
like the other events. "Use this plan" also sends the existing `plan_built`, so the share of plans
that come from suggestions is `suggestion_used / plan_built`.

The backend accepts only events on its list, so the list grows first (slice A) and the app sends
the event only after that deploys. The class metrics endpoint adds a `suggestions_used` count.

Nothing is logged about which places were suggested.

## Rollout

- Slice A (backend event) deploys on its own first; it changes nothing for the current app.
- The iOS slices ship in the next App Store version after 1.0.1. There's no remote switch; the
  feature is on for everyone on that version.
- If it misbehaves, the fix ships as an app update; the backend event can stay.

## Questions

Open: none.

Resolved:

- Source of suggestions: the student's own saves (Abraham, November 21).
- Placement: the empty Today (Abraham, November 21).
- Q-1 Close to the student: v1 keeps stops close to each other only and doesn't read location
  (Abraham approved the recommendation, November 21).
- Q-2 Style: v1 uses existing components only (SP-14); no new visual style before the style guide
  lands. Catherine and Jaden can review the card on TestFlight.
- Q-3 "Not this one": left out of v1.
