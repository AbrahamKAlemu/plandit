# Group plans: brief reviews

The five persona agents read [01-brief.md](01-brief.md) on November 21, 2026. A `must_fix`
blocks the brief; `nice_to_have` doesn't.

## Marcus, Andre and Amara: approve with conditions (6/10 each), the same must_fix

> If that link sits on a blank page for a minute I'm closing it. (Marcus)

> If my link takes a minute, everyone's already moved on to someone else's idea. (Andre)

> If my friends tap it and stare at a blank screen for a minute, they'll say "it's broken" in the
> chat. (Amara)

| must_fix | Disposition |
|---|---|
| The link page must load in a few seconds even after the server has been idle. Settle Q-1 before mode 1 ships; make it a requirement. | **Fixed:** new requirement GV-11 (under 3 s on the first tap after an idle server). Mode 1 waits for it (plan, rollout step 1). Q-1 now asks only *how*: Render Starter ($7 a month, recommended) or an outside keep-awake ping. Both are a paid or new service, so it's Abraham's call. |

Their nice-to-haves:

- **Marcus:**
  - A friend's free time starts at the whole range. **Applied** (GI-2).
  - A "can't eat there" mark in mode 2. Deferred.
  - Keep the clash message plain ("Marcus is only free 7 to 10"). Noted for build.
- **Andre:**
  - Names on the page. Supports Q-2.
  - Friends suggesting new spots by link. **Not taken:** it breaks the guardrail that friends only
    see the organizer's places.
  - Freshness of saves. Covered for suggestions by suggested-plans SP-19; deferred here.
  - A short default deadline for a plan today. **Applied** (GI-1).
  - Seeing which stops the lowest budget cut. Deferred.
- **Amara:**
  - Keep time, first stop and per-person cost at the top. **Applied** (GV-12).
  - Build early with whoever answered, and show the deadline to friends. **Applied** (GI-5, GI-2).
  - Show the budget used without naming whose it is. **Applied** (GI-5).
  - "Plan with friends" and "Edit with friends" are too alike. **Applied:** mode 2 is now "Ask
    friends what works".
  - A count badge for new answers. Deferred, since there's no push.

## Sofia (persona-sofia): approve, 8/10, no must_fix

> This turns the "we should go sometime" group chat into a plan built only from places I already
> saved, with friends needing no app and no sign-up.

Nice to have:

- Q-1 before mode 1 (now GV-11).
- A short deadline for today (applied).
- Show the place's address or source post on the mode 2 page (deferred; the source post is
  someone else's content, so it needs its own look).
- Keep sharing one tap when going solo (noted for build).
- Universal links before pushing mode 3 (Q-3).
- Names on the page (Q-2).

## Grace (persona-grace): approve, 8/10, no must_fix

> For once a group day is planned around what I can afford instead of me quietly dropping out.

Nice to have:

- Mode 2 prices in real dollars. **Applied** (GI-2; architecture `costText`).
- Say whether the budget includes the train, and count fares against it. **Applied** (GI-2,
  GI-5).
- The guardrail line said mode 1 asks each person's budget; it doesn't. **Fixed.**
- A quiet "Too pricey for me" reason on swaps. Deferred.
- A per-person total with fares in the page header (the page already shows the total cost; kept
  by GV-12).
- Directions to the first stop for friends without the app (deferred; the page has "Open in
  Maps").

## Result

The one must_fix (fast first load) is now requirement GV-11 and gates mode 1's release. How to
meet it (Q-1) is Abraham's call, because both options are a paid or new service.

Copy changes: "Ask friends what works" (was "Plan with friends") and "Your budget for the day,
train included".

All three named what would flip them: make a fast first load a requirement and settle Q-1 before mode 1 ships. GV-11 and the rollout gate do that, so their verdicts were not re-run.

November 21: Q-1 resolved without a paid plan. A cron job on Supabase already keeps Render awake. GV-11 is still measured before mode 1 ships.
