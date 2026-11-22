# Group plans: progress

Documents: [brief](01-brief.md) · [brief reviews](01-brief_reviews.md) ·
[architecture](02-architecture.md) · [plan](03-plan.md)

## Summary

Design written November 21, 2026, for all three modes. Waiting for Abraham's approval; nothing
is built.

## Attention needed

- Abraham: approve the dossier, or change it.
- Q-2 to Q-5 (Q-1 is resolved): names on the page, universal links later, the database cache for
  rate limits, and the order of the modes.
- #41 (row level security) must be merged before any group slice.

## Phases

| Phase | Status |
|---|---|
| Clarify | Done: all three modes (Abraham, November 21). |
| Brief, architecture, plan | Drafted November 21. |
| Persona review | Done November 21: 2 approve, 3 approve with one shared must_fix, now GV-11. [01-brief_reviews.md](01-brief_reviews.md) |
| Human approval | Waiting. |
| Build (G0 to G3b) | Not started. |
| Verify, ship, learn | Not started. |

## Tasks and evidence

None yet.

## Decisions and events

- November 21: Q-1 resolved. A cron job on Supabase already keeps Render awake, so links meet GV-11
  without a paid plan. Still measured before mode 1 ships.
- November 21: Abraham chose all three modes.
- November 21: no push, email or real-time service; the app checks for changes while it's open.
- November 21: friends' only free text is a first name. Swaps are picks from the organizer's own
  saves.
- November 21: group plans live on the server, never in the per-account snapshot.
