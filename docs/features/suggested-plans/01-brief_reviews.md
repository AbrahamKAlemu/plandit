# Suggested plans: brief reviews

The five persona agents read [01-brief.md](01-brief.md) on November 21, 2026. A `must_fix`
blocks the brief; `nice_to_have` doesn't.

## Andre (persona-andre): approve with conditions, 5/10, 2 must_fix

> One tap from my saves to a plan for tonight is useful, but nothing stops it from building a plan
> around a pop-up that ended last week or a spot I saved in June.

| must_fix | Disposition |
|---|---|
| Never suggest something that's already over (pop-ups, sample sales). | **Fixed:** SP-19. A caption date that has passed, or a temporary post with no date saved more than 14 days ago, is left out of suggestions. |
| Favor recent saves in the ranking. | **Fixed:** SP-20, plus recency in the score (architecture step 4). |

Nice to have: a time cue on the card ("Saved 2 days ago"), a heading tied to the time of day,
plainer stale message (applied), dismissing a card (brief Q-3), and starting near the student
(brief Q-1).

## Sofia (persona-sofia): approve, 8/10, no must_fix

> This is the feature I've been waiting for.

Nice to have:

- How far the first stop is from her (brief Q-1, deferred).
- Longer than 4 hours on weekends (deferred; see below).
- Plainer stale message (applied).
- "Edit" instead of "Change it" (kept; the other four didn't raise it).
- "Show me another" (brief Q-3).
- Saying "food + a walk" on the card (deferred).

## Grace (persona-grace): approve, 8/10, no must_fix

> Plans made only from places I already saved, with a real dollar total that includes the subway
> and always fits my budget, are a solid yes for me.

Nice to have:

- Say the total includes the subway. **Applied:** "$24 each with subway".
- Show the money left of the budget (deferred, to keep one facts line).
- Say whether there's a train ride. **Applied:** "with subway" or "all walking".
- Plainer stale message (applied).

## Amara (persona-amara): approve, 7/10, no must_fix

> It turns my pile of "we need to go here" saves into a day with a time, a set of stops and a price
> in one tap.

Nice to have:

- Make the cost read as per person. **Applied:** "$24 each".
- Point to "Send plan to friends" after using a plan (deferred to build; the share button is
  already in Today's header).
- Use the group's lowest budget once group plans ship (noted in the group-plans dossier).
- A more prominent start time (left to the style review, brief Q-2).

## Marcus (persona-marcus): approve, 7/10, no must_fix

> One tap to a plan that fits the budget and skips closed places is what I want, and the brief is
> upfront that it does nothing for me until I've saved a couple of places.

Nice to have:

- Distance from him (brief Q-1).
- Hide cards when he's in another city (deferred; needs location).
- Mark stops whose hours are unknown. **Applied:** "check hours".
- A shorter window ("I've got 2 hours"), deferred.
- Plainer stale message (applied).
- A faster way to get the first saves (out of scope).

## Result

Both must_fix items are fixed in the brief, architecture and plan (SP-19, SP-20). Copy changes
from the nice-to-haves:

- "$24 each with subway" / "$24 each, all walking";
- "check hours";
- "It's later now, so these plans changed."

Deferred for Abraham:

- start near the student (Q-1);
- "Not this one" (Q-3);
- windows other than 4 hours.

Andre named what would flip him: "skip saves whose end date has passed and rank recent saves above old ones". SP-19 and SP-20 do exactly that, so his verdict was not re-run.
