# Group plans: plan

Status: approved by Abraham, November 21, 2026. Brief: [01-brief.md](01-brief.md). Architecture:
[02-architecture.md](02-architecture.md).

## Slices

Each slice is its own PR, and the app and the pages keep working after each one lands. #41 (row
level security on every table, plus the test) must be merged first.

| Slice | Outcome | Depends on | Lands safely because |
|---|---|---|---|
| G0. Public form basics (backend) | `public_forms` (cookie, rate limit with a database cache, name check), `retention`, CSP on `/p/` | #41 | No new behavior on the pages beyond headers. |
| G1a. Answers on the plan page (backend) | `ShareAnswer`, the form on `/p/`, owner answers API, new optional payload fields | G0 | The form only shows on plans shared with `answers: true`, which only the G1b app sends, so every existing page looks the same until G1b ships. |
| G1b. Answers in the app (iOS) | Stop ids and swap options in shares, the answers summary, "Swap it" | G1a deployed | Ships in an app version; old versions ignore answers. |
| G2a. Friends' input links (backend) | `GroupRequest`, `GroupAnswer`, `/g/` pages, owner API, `request` on shares | G1a | Nothing creates requests until G2b. |
| G2b. Ask friends what works (iOS) | Create a request, answers screen, `GroupInputs`, planner priorities, build and share | G2a deployed, G1b | New entry point only. The planner change is a no-op at equal priority. |
| G3a. Group plans (backend) | `GroupPlan`, `GroupMember`, versioned API, invites, `/j/` page | G0 | Unused until G3b. |
| G3b. Edit together (iOS) | `GroupPlanStore`, `PlanEdit`, polling, join by link, Today switcher, rollover | G3a deployed | New screens and a new store. Personal plans and sync are untouched. |
| G-web. Privacy and terms (Jaden's repo) | GS-6 text for each mode | Before each app submission | Text only. |

Integration owner: the main thread (orchestrator). Each backend slice deploys before its iOS
slice. Mode 1 (G0, G1a, G1b) is one app version; modes 2 and 3 follow in later versions (brief
Q-5).

## Workstream contracts

### G0. Public form basics

- `CACHES["throttle"]` is a `DatabaseCache` with the table `plandit_throttle_cache`. A migration
  creates it and turns on RLS. Tests use `LocMemCache` for the alias.
- `rate_limited(key, limit, window_seconds) -> bool`.
- `responder_token(request, response, scope) -> str`: reads or sets the cookie and returns its
  SHA-256 hex.
- `clean_first_name(value) -> str` raises `ValidationError`. The blocklist lives in
  `plandit/core/data/name_blocklist.txt`.
- `purge_expired(now)` and `manage.py purge_expired`.
- The CSP helper is applied to `/p/` (and later to `/g/` and `/j/`). Check that
  `shares/plan.html` has no inline script and that its styles stay within the policy.

### G1a, G1b

As in the architecture. G1a includes tests for:

- every owner endpoint called as an outsider (404);
- CSRF rejection;
- the per-IP limit and the 50-answer cap;
- changing an answer from the same cookie;
- another cookie not being able to change it;
- dropping swaps for removed stops;
- cascade on stop sharing;
- `Cache-Control: private, no-store` and the CSP header.

G1b adds `ShareAnswersTests`, `SwapOptionsTests` and the UI test `ShareAnswersFlowTests`, which uses
a DEBUG stub client with fixed answers.

### G2a, G2b

G2b's `GroupInputs` and the planner priority change are written test-first. Every existing
`DayPlannerTests` case passes unchanged.

### G3a, G3b

- G3a tests cover:
  - isolation for every endpoint, for an outsider and for a removed member;
  - 409 on a stale `baseVersion`;
  - `select_for_update` under two concurrent PUTs, using a threaded test with
    `transaction=True`;
  - 304 with `If-None-Match`;
  - invite token replacement;
  - the 8-member limit;
  - the size limits;
  - cascade on account deletion.
- G3b tests `PlanEdit.apply` for every edit, against a plan where its stop was removed, reordered
  or changed. A UI test drives two simulated members against a stub server.

## Verification

| Requirement | Acceptance/failure case | Command/observation | Owner | Evidence/status |
|---|---|---|---|---|
| GV-1 | A name of 1 to 30 allowed characters and "I'm in" gives 303 and is stored; an empty name, 31 characters or a blocked word gives 400 with the form shown again. | `pytest plandit/shares/tests/test_answers.py` | G1a builder | not run |
| GV-2 | Picking an alternate the organizer included is stored; an alternate id that isn't on the stop is ignored. | same | G1a builder | not run |
| GV-3 | The page lists the in-count and at most 3 "in" names; "out" names never appear in the HTML. | same (HTML assertions) | G1a builder | not run |
| GV-4 | The same cookie updates or deletes the answer; another cookie creates a new answer and can't touch the first. | same | G1a builder | not run |
| GV-5 | Today shows counts, names and swap marks after opening; it refreshes on foreground at most every 10 s. | `ShareAnswersTests`; `ShareAnswersFlowTests` | G1b builder | not run |
| GV-6 | "Swap it" replaces the stop at the same position, replans times, re-shares; Undo restores the old stop. | `ShareAnswersTests.testSwap`; UI test | G1b builder | not run |
| GV-7 | The owner's DELETE removes the answer from the API and the page; anyone else gets 404. | `test_answers.py`; UI test | G1a, G1b builders | not run |
| GV-8 | Re-sharing without a stop drops swaps for it; other answers stay. | `test_answers.py` | G1a builder | not run |
| GV-9 | Alternates are only the organizer's saves, same category, within 1.2 mi, open and in budget; the preview lists them; with the toggle off, the payload has none. | `SwapOptionsTests`; preview snapshot | G1b builder | not run |
| GV-10 | Stop sharing deletes the answers (CASCADE). | `test_answers.py` | G1a builder | not run |
| GV-11 | After the service has been idle for at least 1 hour, the first tap on a `/p/` and a `/g/` link from a phone on cellular shows the page within 3 s. | Timed by hand three times on a phone, after an idle hour, with the Supabase keep-awake job running | Orchestrator | not run |
| GV-12 | On a 390-pt-wide phone, the time, the first stop and the per-person cost are visible without scrolling, above the form. | Screenshot on the iPhone simulator's Safari | G1a builder | not run |
| GI-1 | A request with 2 to 10 places, a day 0 to 14 days out, a range ≥ 1 h and a deadline is created; other values give 400. | `pytest plandit/plans/tests/test_requests.py` | G2a builder | not run |
| GI-2 | A friend's answer is stored and editable by the same cookie until the deadline; > 3 stars, a budget out of range or a window outside the range give 400. | same | G2a builder | not run |
| GI-3 | After the deadline or once built, POST gives 410 and the page says it's closed. | same | G2a builder | not run |
| GI-4 | The owner API returns every answer; anyone else gets 404. | same | G2a builder | not run |
| GI-5 | Three answers (budgets 20, 40, 60; windows 12–6, 2–8, 1–5) give start 2 PM, end 5 PM, budget 20, and the 7 most-starred candidates. With equal priorities, every existing planner test passes; with priorities, the lowest-priority stop is dropped first. | `GroupInputsTests`; `DayPlannerTests` | G2b builder | not run |
| GI-6 | Windows 12–2 and 4–6 give `.clash` with both names; leaving one out gives a plan. | `GroupInputsTests.testClash`; UI test | G2b builder | not run |
| GI-7 | After building, `/g/<slug>` redirects (302) to `/p/<plan slug>`, and the plan is in Today. | `test_requests.py`; UI test | G2a, G2b builders | not run |
| GI-8 | A friend's page HTML has no other friend's budget or window, only the count. | `test_requests.py` | G2a builder | not run |
| GE-1 | A group is created from a plan; the 9th join gives 404. | `pytest plandit/groups/tests/` | G3a builder | not run |
| GE-2 | The invite preview shows the organizer's first name, the date and the member count; joining adds a member with the first word of their profile name. | same; `JoinFlowTests` | G3a, G3b builders | not run |
| GE-3 | Each edit type applies locally and PUTs. | `PlanEditTests`; `GroupPlanStoreTests` | G3b builder | not run |
| GE-4 | With the plan on screen, a server version bump shows within 15 s; a 304 doesn't redraw. | `GroupPlanStoreTests.testPolling` (clock injected) | G3b builder | not run |
| GE-5 | Two edits to different stops both land; an edit to a removed stop isn't applied and the message names who removed it. Server: a stale `baseVersion` gives 409; two concurrent PUTs give one 200 and one 409. | `PlanEditTests`; `pytest …test_concurrency.py` | G3a, G3b builders | not run |
| GE-6 | With a personal plan and a group plan on the same day, Today shows both behind a switcher; editing one never changes the other or the snapshot's `today`. | `GroupPlanStoreTests`; UI test | G3b builder | not run |
| GE-7 | The organizer removes a member, and that member's next poll gets 404 and the plan disappears; a member leaves themselves; a non-organizer can't remove others (404). | pytest; `GroupPlanStoreTests` | G3a, G3b builders | not run |
| GE-8 | After replacing the token, the old token's preview and join give 404. | pytest | G3a builder | not run |
| GE-9 | After the date, each member gets one `PastPlan`; a second device doesn't add it again. | `GroupPlanStoreTests.testRollover` | G3b builder | not run |
| GE-10 | Deleting the organizer's account deletes the group; deleting a member's account removes only their membership. | pytest (account deletion tests extended) | G3a builder | not run |
| GS-1 | The RLS test passes with the new tables; every owner or member endpoint gives 404 to an outsider. | `pytest tests/test_row_level_security.py`; isolation tests per slice | Each backend builder; reviewer (xhigh) | not run |
| GS-2 | The 21st answer from one IP within an hour gives 429 and the page says to try later; the 51st answer on a link gives 429. | `test_public_forms.py` | G0 builder | not run |
| GS-3 | A POST without the CSRF token gives 403; pages carry the CSP; the page renders with the CSP on (no blocked styles). | pytest; browser check of `/p/` with the console open | G0 builder | not run |
| GS-4 | Names outside the rules or on the blocklist give 400; the report link is on every public page. | `test_public_forms.py` | G0 builder | not run |
| GS-5 | `purge_expired` deletes answers, requests and groups 30 days after their date and nothing newer. | `test_retention.py` | G0 builder | not run |
| GS-6 | plandit.app/privacy and /terms describe each mode before that mode's app version is submitted. | Read the live pages | Abraham with Jaden | not run |
| GS-7 | No code path reads answers or group plans outside their endpoints and metrics counts. | Reviewer reads the diff | Reviewer | not run |
| GC-1 | Persona agents return no `must_fix` on the brief's copy; no word from AGENTS.md's list appears. | [01-brief_reviews.md](01-brief_reviews.md); grep the diff | Orchestrator | not run |
| Analytics | The metrics endpoint returns the counts from the brief and no names. | metrics tests | Each backend builder | not run |

Full lanes before each PR: `cd backend && pytest` (local Postgres, never `backend/.env`) and
`ruff`; the iOS unit and UI tests on the iPhone 17 Pro simulator; and before a TestFlight upload, an
iOS 18 run.

## Testing checkpoint

An independent test-planning pass is selected for G3 (concurrency and sync) before G3a starts,
because a wrong rebase silently loses someone's edit. Modes 1 and 2 are covered by the table above.

## Review owners

- G0, G1a, G2a, G3a touch public writes, tokens and data isolation: `reviewer` at xhigh.
- G1b, G2b, G3b: `reviewer` at high; G3b at xhigh for the sync and rebase code.
- Before each mode's release: an independent completion review against that mode's rows, plus one
  walk of the changed flow (browser for the pages, simulator for the app).

## Human approval

Approved by Abraham on November 21, 2026 ("Please do everything and do what you recommend"), with
the brief's recommended answers to Q-2 to Q-5. Q-1 was resolved by the Supabase keep-awake job.
Merging stays with Abraham.

## Rollout and final checks

For each mode:

1. Mode 1 only: GV-11 measured before the app version is submitted.
2. Merge the backend slice; Render deploys and runs the migration. Then, from a test account,
   create, answer and delete once in production and confirm it works. Check the RLS query from
   #41's PR returns no rows.
3. Merge the iOS slice; TestFlight; try it with two phones (or a phone and a browser) on real
   links.
4. Website PR on Jaden's repo for GS-6, merged and live.
5. App Store version:
   - update What's New and the Review Notes (what friends can enter, the limits, the report link,
     how to remove answers or members);
   - for mode 3, give App Review a second demo account already in a group with the first;
   - reset the demo accounts after recording.
6. After a week, read the metrics counts.
7. Update AGENTS.md "What we learned" in the cleanup step.
