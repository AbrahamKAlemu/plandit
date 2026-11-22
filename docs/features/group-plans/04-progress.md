# Group plans: progress

Documents: [brief](01-brief.md) · [brief reviews](01-brief_reviews.md) ·
[architecture](02-architecture.md) · [plan](03-plan.md)

## Summary

Approved November 21, 2026. All three modes are built and merged (November 22): friends answer a shared
plan (mode 1), friends' input links (mode 2), and editing one plan together (mode 3). Plans for a later
day were dropped.

## Attention needed

- Abraham: read the `proxy chain:` lines in Render's logs (the dashboard is blocked for Claude).
  Four requests were sent from a laptop on November 22 at 11:14:45 to 11:14:49 EST to
  `/p/measure-hops-*`: two plain, one with one forged X-Forwarded-For entry, one with two.
  `true_client_ip_from_right=N` on the plain lines is the hop count. If it isn't 3, set
  `TRUSTED_PROXY_HOPS` to N in Render; then the log line can be removed.
- Abraham: merge #57 (the metrics become public, counts only, so the course staff's tools need no key) or
  close it and send the key yourself. Claude's merge of it was blocked.
- GS-6: #58 put the group plans text in this repo's `website/privacy.html`. Port it to Jaden's repo
  (the live plandit.app) before an app version with group plans is submitted, and set the effective
  date then.
- Don't upload a TestFlight build with group plans until the iOS 18 run in AGENTS.md is done.
- Before group plans reach testers (Abraham): the two-phone check on real links, a create, join and
  delete smoke test against production, and a second demo account for App Review to show mode 3.
- Follow-up: the 30-day deletions run only when a link or group route is used, not on a schedule (the
  privacy text says so). A timed purge would let the policy give a firm date.

## Phases

| Phase | Status |
|---|---|
| Clarify | Done: all three modes (Abraham, November 21). |
| Brief, architecture, plan | Drafted November 21. |
| Persona review | Done November 21: 2 approve, 3 approve with one shared must_fix, now GV-11. [01-brief_reviews.md](01-brief_reviews.md) |
| Human approval | Approved November 21 with the recommended answers. |
| Build (G0 to G3b) | Done November 22. G0 to G3a, the backend fixes (#55) and the privacy text (#58) are merged and deployed; the app's store (#56) and screens (#59) are merged. |
| Verify, ship, learn | Completion reviews done November 22, no must-fix in any mode. Mode 1: 19 pass, 2 unverified. Mode 2: 16 pass, 1 unverified. Mode 3: 24 pass (GE-1 to GE-10 and the 14-item minimum set), checked against the final logs. Unverified: GV-11 timing on a phone, GS-6 live privacy page. Lessons are in AGENTS.md (#60). |

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
- G2b, `feat/group-requests-app`, #51 (base `feat/group-answers-app`, #50):
  - Tests: the full lane on 9e8fc9c passed 605 unit tests. UI: 85 tests with 2 failures in
    `MapAndBudgetFlowTests` while the Mac was overloaded (load average up to 391). That suite then
    passed 13 of 13 on its own. G2b doesn't change those screens.
  - Contract with G2a, checked against a local backend from #47's branch: create 201, answer 303,
    owner GET 200, share with `request` 201, `/g/` redirects to `/p/`, answer delete 204 then 404,
    close 204, no token 401, request delete 204 then 404.
  - Review (high): round 1 found 4 must-fix (Undo after Build republished the old plan, Try again
    after Undo, Build before answers loaded, daylight-saving times). Later checks found Undo during
    the share, overlapping shares and Today replaced before the share. All are fixed, each with a
    test that failed first. The last fix round wasn't independently reviewed.
  - Copy: Amara's must_fix (preview a later day's plan) is fixed. No must_fix is open.
- G3a, `feat/group-plans-backend`, #53 (base `feat/group-requests-backend`, #47):
  - Tests: 1164 passed on a local Postgres, plus the known date failure fixed in #44. Migrations
    forward, back and forward; `makemigrations --check` clean.
  - The whole minimum set from 03-plan_g3-tests.md is covered. Mutation checks on the locks, and on
    the checks repeated under them, make the race tests fail.
  - Review (xhigh, one round): 1 must-fix (an outsider could get 503 instead of 404 on three
    organizer routes while the group was busy) and 6 nice-to-haves, all fixed. The fixes weren't
    re-reviewed.
  - Copy: 3 personas approve (7), 2 approve with conditions (6). Both must-fixes were about the
    `/j/` page's steps and are fixed.
- Backend fixes, `fix/backend-deletion-races`, #55 (merged November 22):
  - Locks so a sync, share or new row can't deadlock or 500 against account deletion (now 401), group
    plan value checks, the organizer's first name on `/g/`, `/g/` on narrow screens, two metrics.
  - Tests: 1,373 passed on a local Postgres. Each race fix has a test that failed first; reverting
    each fix makes its tests fail.
  - Review (xhigh, one pass): no must-fix. Both nice-to-haves applied (a friends' input link created
    during deletion gave 500, as did 5 other routes; organizers weren't told their name shows). Not
    re-reviewed. Left: the activity write at sign-in, saved-post extraction during deletion, the
    `ShareAnswer` purge without a lock.
- G3b-1, `feat/group-edit-store`, #56 (merged November 22):
  - Tests: full lane on c668690, 757 unit and 85 UI, 0 failures. Contract run against #53's backend.
  - Review (xhigh, one pass): 1 must-fix (a new invite link made on another phone never arrived) and
    5 smaller findings (a stored edit reported as not made, messages lost before a screen listened,
    group responses in the shared URL cache, the cache left on a revoked session, a stored edit
    vanishing). All fixed, each red first. Not re-reviewed.
- G3b-2, `feat/group-screens`, #59 (merged November 22; the join work was built on `feat/group-join`
  and merged into it):
  - Tests: full lane on 99211f6, 850 unit tests, 0 failures; 99 UI tests with 1 failure
    (`AskFriendsFlowTests`, two taps reversed while the Mac's load average was about 215), which passed
    4 of 4 on a rerun.
  - Review (xhigh, one pass): 1 must-fix (an invite pasted in Today's Paste a link was dropped) and 4
    smaller (an open sheet's edit could land on your own plan, map focus in a joined group, fixtures
    sharing stop ids, controls on after 4 AM). All fixed, each red first. Not re-reviewed.
  - Copy (one persona pass with #55's and #58's text): Marcus, Sofia, Grace and Andre approve (7 to 8);
    Amara's must_fix (the invite message promised a plan the web page doesn't show) is fixed. Applied:
    a line under Edit with friends saying who can change it and that the budget shows.
- Privacy text, `docs/privacy-group-plans`, #58 (merged November 22): every sentence traced to code;
  open points are in the PR.

## Decisions and events

- November 22: Abraham dropped the "plans for a later day" slice. A group plan for a later day stays a
  preview with the answers so far, built on the day itself (D1).
- November 22: invite links accept tokens of 16 to 64 URL-safe characters, not exactly 22, so a
  truncated real link says "This invite doesn't work any more" instead of asking for a TikTok link.
- November 22: one review pass and one persona pass covered #55, #56 and #59; fixes weren't
  re-reviewed, as Abraham asked.
- November 22: Abraham asked to keep reviews to a minimum with no rounds, and for Claude to do the
  remaining human steps and follow its own recommendations. Claude merged #38 to #54 (merge commits,
  so stacked branches stay clean; #46, #47 and #53 needed main merged in for one README line). #46
  onward merged before the hop count was read: a wrong count only weakens the per-address answer
  limit, the per-link cap holds, and the fix is an environment variable.
- November 22: `/g/` pages show the organizer's first name (the first word of the profile name; no
  name when it's empty). Friends know whose link it is, and mode 3's join sheet already shows it.
- November 22: the name blocklist was read for #45: 52 whole-word entries, none matching any of
  1,308 common first names. Look-alike letters get past it (mode 1 review); it stays best effort.
- November 22: GI-1's default deadline for a plan today is the earlier of 2 hours from now and the
  range's start, but at least 30 minutes away (G2b). Recorded here; the brief said 2 hours.

- November 22: G3b is split into G3b-1 (the edit model, client and store, unused until the screens
  land) and G3b-2 (the screens), so each PR stays reviewable. Each gets one review round.

- November 22: G3a's purge rules now commit one at a time, and the group rule locks expired groups
  first, so a purge can't deadlock with account deletion. Another member's `editId` gets 400, not a
  replay.

- November 22: the G3 test-planning pass ([03-plan_g3-tests.md](03-plan_g3-tests.md)) found 7
  must_fix design issues in mode 3; all are adopted and 02-architecture.md is revised. In short:
  - edits are by stop id;
  - PUTs are idempotent with an edit log, and a 409 names who changed what;
  - the ETag covers membership;
  - lock order is fixed for account deletion;
  - there's no Undo in group plans for now;
  - removed members can't rejoin.

  It also found that RLS doesn't apply to the API (Django owns the tables), so group isolation rests
  on the API's queries and their tests.

- November 22: Abraham asked for one review round per slice from now on: one code review and one
  persona pass, then fixes, the full test lane and the PR, with no re-review. This applies to G3a
  too unless Abraham asks for more.
- November 22: G2b builds a group plan only on its own day (D1), because the store holds one
  `today`. A later day's plan is previewed with the answers so far. Build reuses Today's existing
  link, `planRequest` syncs last writer wins, and Ask about another day checks the server before
  deleting. A small window remains, because the server's delete doesn't check the status.
- November 22: older planner code adds minutes to the start of the day in 6 places, an hour off on
  daylight-saving days. G2b fixed its own `ClockTime`; a follow-up PR fixes the rest.

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
