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
- #47 (G2a): decide whether `/g/` pages show the organizer's first name.
- #50 (G1b, iOS) is stacked on #49. Don't upload a build with it to TestFlight until #46 is deployed.

## Phases

| Phase | Status |
|---|---|
| Clarify | Done: all three modes (Abraham, November 21). |
| Brief, architecture, plan | Drafted November 21. |
| Persona review | Done November 21: 2 approve, 3 approve with one shared must_fix, now GV-11. [01-brief_reviews.md](01-brief_reviews.md) |
| Human approval | Approved November 21 with the recommended answers. |
| Build (G0 to G3b) | G0 #45, G1a #46, G2a #47 and G1b #50 open. G1a and G2a merge after the proxy-chain measurement. G2b (iOS) next. |
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
- G1a, `feat/group-answers-backend`, #46 (base `feat/group-public-forms`):
  - Tests: 556 passed on a local Postgres. The one failure is the date test fixed in #44.
  - Six deterministic race tests in `test_answer_races.py`.
  - Layout at 390×844 in headless Chrome (GV-12): the time, cost and first stop sit above the form.
  - Review (xhigh): 2 must-fix, both fixed (upper-case answer ids; the delete-while-answering race,
    now handled by locking the link before deleting). A second review of the fixes found nothing.
  - Copy: all five personas approve (8/10 each), no must_fix. Applied: a separate message for a
    full plan, a plainer blocked-name message, and a hint that "can't make it" names aren't shown.
- G2a, `feat/group-requests-backend`, #47 (base `feat/group-answers-backend`):
  - Tests: 753 passed on a local Postgres. The one failure is the date test fixed in #44.
  - Deterministic race tests in `test_request_races.py`. Without the new profile lock, the
    build-while-deleting test deadlocks and returns 500.
  - Review (xhigh): findings fixed in b0388e8 to 20ba1cc. These are the profile lock before marking a
    request built, take-back after the plan is built, `REQUEST_BASE_URL`, and the budget as a $5-step
    select. A second review of the fixes found no must-fix.
  - Copy: two persona rounds, all five approve, no must_fix. The second round (7 to 8) added the
    plan's day to the ready page and "Taking your answer back won't change the plan."
- G1b, `feat/group-answers-app`, #50 (base `feat/suggested-plans-change-it`, #49):
  - Tests: the full lane on 6ed9816 passed (531 unit, 81 UI). The last fix, 2a82d4e, passed 535 unit
    tests plus `ShareAnswersFlowTests`.
  - Contract with G1a, checked against a local backend: the share JSON is accepted (201), answers
    decode, and removing an answer returns 204.
  - Review (high), three rounds:
    - Round 1: 5 must-fix. Four were fixed: the Gregorian date, the first stop's time on Swap it, a
      removed answer coming back, and Keep after the server drops a pick. The fifth, Undo not
      restoring picks, is accepted under GV-8.
    - Round 2: 1 must-fix (the first stop still ahead after a done stop) and three issues where the
      page fell out of step. Page updates now go out one at a time and in order.
    - Round 3: the overlap between Share plan and Stop sharing that could bring a stopped page back
      (GV-10) is fixed. The last check found no must-fix.
    - Each fix has a test that failed first.
  - Copy: all five personas approve (7 to 8), no must_fix. Applied: the undo bar says the link
    updates, "Keep {stop}", and "You'll see their answers in Today."

## Decisions and events

- November 22: G1b's Undo after Swap it restores the plan and its page but not friends' swap picks
  for the replaced stop, as GV-8 says. Links shared by the previous app version load with swaps off,
  so nothing is offered without a preview (GV-9). If the organizer swaps and then builds a new plan
  within 2 s, the old page misses the swap; accepted as low impact.
- November 21: G2a follow-ups noted in #47. The organizer's first name on `/g/` pages is a privacy
  call for Abraham (three personas asked for it). A share without `request` during account deletion
  returns 500, and the purge could deadlock with account deletion at the exact expiry moment.
- November 21: a friend whose answer is on a built request sees a private page with the plan's link
  and "Take back my answer". Everyone else goes straight to the plan.
- November 21: the answer rate limit is 20 per hour per address on each link, not across all links,
  so students behind one campus network don't share one allowance. The 50-per-link cap still holds.
- November 21: "Take back my answer" works on any existing link, even after answers are turned off.
- November 21: `date` is required when `answers` is true (retention needs it), at most 366 days
  ahead. Answers close 30 days after the plan's date.
- November 21: follow-ups noted in #46: a sync during account deletion can deadlock (older code),
  and throttle-table culling under abuse.
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
