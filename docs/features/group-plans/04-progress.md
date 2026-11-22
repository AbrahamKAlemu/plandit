# Group plans: progress

Documents: [brief](01-brief.md) · [brief reviews](01-brief_reviews.md) ·
[architecture](02-architecture.md) · [plan](03-plan.md)

## Summary

Approved November 21, 2026. Building mode 1 (G0, G1a, G1b), then mode 2, then mode 3.

## Attention needed

- Abraham merges each slice's PR (merging is blocked for Claude).
- #41 (row level security) must be merged before any group slice.
- #45 (G0): a human reads the name blocklist before merging. After it deploys, open a shared plan link
  from a phone on cellular and from a laptop, so the `proxy chain:` log lines can set the hop count.

## Phases

| Phase | Status |
|---|---|
| Clarify | Done: all three modes (Abraham, November 21). |
| Brief, architecture, plan | Drafted November 21. |
| Persona review | Done November 21: 2 approve, 3 approve with one shared must_fix, now GV-11. [01-brief_reviews.md](01-brief_reviews.md) |
| Human approval | Approved November 21 with the recommended answers. |
| Build (G0 to G3b) | G0 in review as #45. G1a waits for the proxy-chain measurement after G0 deploys. |
| Verify, ship, learn | Not started. |

## Tasks and evidence

- G0, `feat/group-public-forms`, #45 (base `fix/rls-all-tables`):
  - Tests: 426 passed on a local Postgres. The one failure, `test_event_is_stored`, is fixed in #44.
  - `migrate` forward and back is checked, and `makemigrations --check` is clean.
  - Rendering is unchanged after the styles moved to static files: headless Chrome screenshots are
    byte-identical, with no CSP violations.
  - Review (reviewer, xhigh): one must-fix. The default proxy hop count was likely wrong for
    Render. Fixed by defaulting to 3 and measuring before G1a. Two nice-to-haves were applied: a
    slot expiry margin, and IPv6 counted by /64.

## Decisions and events

- November 21: `client_ip` takes the X-Forwarded-For entry `TRUSTED_PROXY_HOPS` from the right (the
  first entry is client-controlled on Render). The hop count is measured from G0's log before G1a.
- November 21: the CSP's `img-src` also allows plandit.app and www.plandit.app, where the page's
  logo and icons live.
- November 21: the name blocklist (`backend/plandit/core/data/name_blocklist.txt`) needs a human
  read before G0 merges.
- November 21: Abraham approved the dossier and the recommended answers to Q-2 to Q-5.
- November 21: G1a's form only appears on plans shared with `answers: true`, so the backend stays
  inert until the G1b app ships.
- November 21: Q-1 resolved. A cron job on Supabase already keeps Render awake, so links meet GV-11
  without a paid plan. Still measured before mode 1 ships.
- November 21: Abraham chose all three modes.
- November 21: no push, email or real-time service; the app checks for changes while it's open.
- November 21: friends' only free text is a first name. Swaps are picks from the organizer's own
  saves.
- November 21: group plans live on the server, never in the per-account snapshot.
