# App polish for 1.0.1: brief reviews

Persona gate, round 1 (November 18, 2026), on [01-brief.md](01-brief.md) with
[02-architecture.md](02-architecture.md) as context.

## Sofia (persona-sofia): approve, 8/10, no must_fix

| Nice to have | Disposition |
|---|---|
| Say in the share confirmation that the place is found later | Adopted into SHR-1: "Plandit finds the place next time you open it." |
| Don't make several shares wait one after another when the server is asleep | Adopted into PRC-1: shares are looked up at the same time, and the list fills in as each finishes. |
| "Add details" and "Check details" are too close | Adopted into PRC-5: "Add the place" and "Check this place". |
| "Add to my next free day" instead of only today | Not in scope: planning ahead is a planner change, not polish. |
| Open a past plan to resend or redo it | Not in scope: 1.0 doesn't store past plans' stops (brief, Not in scope). |
| Import many old TikTok favorites at once | Not in scope. Noted as the next request. |

## Marcus (persona-marcus): approve, 7/10, no must_fix

| Nice to have | Disposition |
|---|---|
| The brief claims him as an audience but only the Plan button helps him | Adopted: "Who it's for" now says so plainly. |
| With no pending shares, never jump away from Today | Adopted into PRC-1. |
| Plan building must not wait on the sleeping server | Already true: the planner runs on the phone. No change. |
| W rows weren't written yet | Adopted: round 2 of the persona gate covers the W rows. |
| Large text on a small phone mustn't shrink tab targets | Adopted: the Plan table checks NAV-3 on the smallest iPhone simulator at the largest text size. |

## Andre (persona-andre): approve, 7/10, no must_fix

| Nice to have | Disposition |
|---|---|
| Show when the original post went up | Not in scope: extraction doesn't return the post's date today; that's an extraction change. |
| Read time-limited cues ("ends Sunday", "pop-up") | Not in scope. |
| Make old saves look old | Not in scope. |
| "Add the place" should take a store name or cross streets | Already true: the search asks for a name, an address, or both. No change. |
| Keep the 2 s auto-close | Kept (SHR-1). |
| Move to Render's paid plan soon | Abraham's call; still open from November 11. |

## Grace (persona-grace): approve, 7/10, no must_fix

| Nice to have | Disposition |
|---|---|
| Recent plans: say whether fares are included, real dollars, budget mark | Adopted into PRO-2 (fares stated when included; dollars only; budget mark when the plan recorded one). Plans from before accounts have no recorded budget, so they can't show the mark. |
| Before "Add to today's plan", show the cost, distance and new day total | Not in scope: a planner change. After adding, the post already shows the stop's time and any budget overrun. |
| Distance and price on each "Pick the place" card | Not in scope: changes the November 8 candidate-card decision (name and one-line address). |
| W rows mustn't add a sign-up wall, trial, or price ranges in place of numbers | Accepted as a constraint on the W rows. |
| Keep "Still looking. This can take up to a minute." | Kept (PRC-2), then reworded on November 18 to "This can take a minute or two." after the slice B review: the timeout plus one retry can run about two minutes. |

## Amara (persona-amara): approve, 7/10, no must_fix

| Nice to have | Disposition |
|---|---|
| Say the group plan share is unchanged | Adopted: listed under Not in scope as unchanged. |
| Label Recent plans cost "per person" | Adopted into PRO-2. |
| Add a saved place to a plan for another day | Not in scope: a planner change (same as Sofia's request). |
| Share several forwarded TikToks at once | Not in scope. |
| Error copy should say Instagram posts work too, not only Reels | Adopted into SHR-4. |

## Result

Round 1: five approvals, no must_fix.

# Round 2: Walkthrough fixes (W-1 to W-17), November 18

Same five personas, judging only the W rows and the "Seen but not in scope" line.

| Persona | Verdict | Score | must_fix |
|---|---|---|---|
| Sofia | approve | 8 | none |
| Marcus | approve | 7 | none |
| Andre | approve | 7 | none |
| Grace | approve | 8 | none |
| Amara | approve | 7 | none |

| Nice to have | From | Disposition |
|---|---|---|
| Give W-17 a ship rule in case PR #28 slips | Marcus, Andre, Amara | Adopted into W-17: 1.0.1 ships without it and it moves to 1.0.2 as an open item. |
| Track "late lunch after dinner" with an owner, not only "reported" | All five | Adopted: a GitHub issue for Eldad, opened once Abraham approves the dossier. |
| W-16: say what kind of ride ("2 subway rides"); a "ride" could read as Uber | Grace, Sofia | Adopted into W-16. |
| W-16: show ride minutes too | Marcus, Andre | Not adopted: the summary holds one value, and each trip already shows its minutes. |
| W-16: keep fares in the per-person cost | Amara | Already true (PRO-2 and 1.0's cost). |
| W-2: say why a stat shows "–" | Amara | Adopted into W-2 ("Older plans didn't record this."). |
| W-2: say how much under budget | Grace | Adopted into PRO-2 for each recent plan row ("$22 under"). |
| W-1, W-2: "Today," reads like the tab name | Sofia | Adopted: now "In 1.0,". |
| W-1: check the empty Today's "Plan a day" first | Marcus | Already in the plan: W-1's checks include the empty Today. |
| W-12: offer places named in the caption as suggestions | Sofia | Not in scope: an extraction change. |
| Overlapping map pins near the top of the next release | Grace, Andre, Sofia | Noted in the brief as the first candidate for the next release. |
| W-17: show walking time and station next to arrival | Grace | Not in scope: a planner change. |
| Keep the source label ("from this TikTok") on Today too | Andre | Not in scope. |

## Result

Round 2: five approvals, no must_fix. The persona gate passes for the brief.

# Round 3: Design feedback (D-1 to D-8), November 18

Same five personas, judging only the D rows and their "Not in scope" list.

| Persona | Verdict | Score | must_fix |
|---|---|---|---|
| Sofia | approve | 8 | none |
| Marcus | approve with conditions | 6 | D-1 must say Skip ends the whole tutorial in one tap |
| Andre | approve | 7 | none |
| Grace | approve | 8 | none |
| Amara | approve | 7 | none |

**Marcus's must_fix:** fixed. D-1 now says Skip on any page closes the whole tutorial and opens the
map in one tap, and it's never shown again. The build already behaved this way; the D-1 check
covers Skip from the first page.

| Nice to have | From | Disposition |
|---|---|---|
| "Added" is ambiguous in Saved, where everything is already added | Sofia, Andre | Adopted: the badge and status word are "In plan" (D-5, PRC-5). Flagged to the designer. |
| Say what + does with no plan today | Sofia | Adopted into D-5: starts a plan or opens the planner with the place picked; never a dead tap. |
| Keep + one tap with no confirmation | Marcus | Adopted into D-5. |
| Show a price on rows that aren't free | Grace, Amara, Sofia | Not adopted: the design feedback removes prices from rows on purpose. Raised with the designer. |
| Mark "Free" as an estimate when Plandit guessed it | Grace, Amara | Not adopted: the rest of the app shows Plandit's estimate the same way. Raised with the designer. |
| "Neighborhoods explored" vs the brand watch list | Amara, Sofia | Kept: it's a stat label, not a headline (AGENTS.md bans those words as headlines). Raised with the brand-position owners. |
| Tutorial copy changes (group nod; "what it all costs"; time first; "spots you saved"; a line for people with no saves) | Amara, Grace, Marcus, Andre | Not adopted: the copy is the designer's, changed only where it was inaccurate (page 2). The planner doesn't ask solo or group. Passed to the designer. |
| Show a save's age on rows | Andre | Not adopted: the feedback removes dates; Sort covers it. |
| Small TikTok or Instagram mark on rows | Sofia | Not adopted: the feedback removes the source line. |
| Category order by recent saves; "Closest to me" sort; an "Under $15" filter | Andre, Sofia, Amara | Not in scope. |
| Keep "$22 under" visible on small phones | Grace | Adopted as part of PRO-2's check. |
| Share a Saved list | Amara | Not in scope. |
| Give Home a sense of time when it returns in 1.0.2 | Andre | Noted for 1.0.2. |

## Result

Round 3: five approvals after Marcus's one must_fix was fixed. The persona gate passes for the D rows.
