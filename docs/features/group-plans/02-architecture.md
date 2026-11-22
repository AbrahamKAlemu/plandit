# Group plans: architecture

Status: approved by Abraham, November 21, 2026. Brief: [01-brief.md](01-brief.md). Verification:
[03-plan.md](03-plan.md#verification).

## Summary

Modes 1 and 2 extend the server-rendered pages from #37. Friends answer with plain HTML forms,
with no JavaScript, accounts or app, and the organizer's app reads the answers through new
owner-only API endpoints. The planner stays on the phone: the server stores answers, and the app
turns them into a plan.

Mode 3 adds a server-side `GroupPlan`, a JSON plan with a version number, edited by its members
with compare-and-swap writes. Each app checks for new versions every 15 seconds while the plan is
on screen. Group plans never go into the per-account `AppSnapshot`, which is last writer wins and
belongs to one person.

All new tables get row level security. The public forms get CSRF protection, a Content Security
Policy and rate limits.

## Existing structure (reconnaissance, November 21, main at f4167f5)

- **Shared plans** (`backend/plandit/shares/`):
  - `SharedPlan` has `slug` (10 random characters), `owner` (Profile, CASCADE), `plan_id` and
    `data` (JSON, formatted on the phone), with one link per (owner, plan).
  - `POST /api/shares/` creates the link or updates it in place. `DELETE /api/shares/<slug>/` is
    owner-only and answers 404 otherwise.
  - `GET /p/<slug>` renders `shares/plan.html`, with `X-Robots-Tag: noindex`,
    `Cache-Control: public, max-age=60`, `Referrer-Policy: no-referrer`, and no CSP.
  - `share_url()` uses `SHARE_BASE_URL` (plandit.app once the site forwards `/p/`), otherwise the
    API's own host. Since G0 the page's styles are static files at `/static/shares/`, so the site
    must forward that path too when `SHARE_BASE_URL` moves.
- **Share payload** (`ios/Plandit/Models/SharedPlan.swift`): `SharedPlanPayload` holds the title,
  `dateText`, stops (name, place, address, texts and coordinates) and legs. Stops have no ids, and
  the date is only text. `SharedLink` (slug, url, planID, showPrices, note) lives in the app's
  store.
- **Sync** (`core/models.py:102`): `AppSnapshot` is one JSON per Profile. PUT is last writer wins
  and the version isn't checked. The app pulls on foreground (at most every 10 s) and pushes 2 s
  after a change.
- **Auth**: `SupabaseJWTAuthentication`; there's no anonymous identity. DRF throttles exist
  (`ScopedRateThrottle` for events and metrics, `AnonRateThrottle` for the waitlist). The cache is
  `LocMemCache`, which is per gunicorn worker (2 workers) and empties when Render sleeps or
  deploys.
- **Hosting** (`render.yaml`): free plan, which sleeps after 15 idle minutes (30 to 60 s cold
  start). A cron job on Supabase keeps it awake (Abraham, November 21). The Dockerfile runs
  `migrate` and then gunicorn.
- **Planner** (`Services/DayPlanner.swift`): it includes every candidate, then drops stops by
  rule: closed, then the day runs too late (drop the stop that frees the most time), then over
  budget (drop the stop that saves the most money). It has no notion of priority. It tries every
  order up to 7 candidates. `PlanEditing.swift` has `inserting`, `reordered` and
  `edited(keeping:)` for edits that replan times.
- **No universal links** or associated-domains entitlement. The share extension and "Add a link"
  accept any URL and route it to place finding.
- **Row level security**: #41 turns it on for every table and adds a test that fails on any
  public table without it.

## Affected components

### Mode 1: answer the plan link

**Backend**

`ShareAnswer` model:

| Field | Notes |
|---|---|
| id | UUID |
| shared_plan | FK to SharedPlan, CASCADE (GV-10) |
| responder | SHA-256 of a random 32-byte cookie token (only the hash is stored) |
| name | ≤ 30 characters |
| status | `in` or `out` |
| swaps | JSON `{stop_id: alternate_id or null}` |
| created_at, updated_at | |

Unique on (shared_plan, responder).

- RLS migration for the table.
- `POST /p/<slug>/answer` (form):
  - checks CSRF, rate limits, validates the answer and upserts it by cookie;
  - sets the cookie `pa` with Path=/p/<slug>, HttpOnly, Secure, SameSite=Lax and a 30-day max age;
  - redirects (303) to the page.
- `POST /p/<slug>/answer/delete` removes the caller's own answer.
- `GET /p/<slug>` adds the form, the "in" names and the viewer's own answer, only when the plan was shared with `answers: true` (the G1b app sends it). Older shares look exactly as now, and the answer POST answers 404 for them, so nothing is collected before the app and the privacy policy are ready. Cache-Control becomes
  `private, no-store`, because the page now depends on the cookie, and a CSP is added (GS-3).
- `GET /api/shares/<slug>/answers/` and `DELETE /api/shares/<slug>/answers/<id>/` are owner-only,
  404 otherwise.
- `SharedPlanSerializer` accepts an optional `answers` flag (default false), plus optional `stops[].id`, `stops[].alternates` (≤ 2 of `{id, name,
  neighborhood, kind, costText}`, in dollars as the plan page shows them) and `date` (ISO). Old apps that don't send them keep working;
  without stop ids, the swap buttons are hidden.
- When the plan is updated, `swaps` entries for stop ids no longer in `data` are dropped (GV-8).

**iOS**

- `SharedPlanPayload.Stop` gains `id` and `alternates`; the payload gains `date`.
- `SwapOptions.pick(for:stop, saves:, plan:)` chooses up to 2 alternates per stop: same category,
  within 1.2 miles, open at the stop's time, and not making the plan go over budget.
- The share preview shows them and has the "Let friends suggest swaps" toggle.
- `ShareAnswersClient` fetches answers on Today's appearance and on foreground, at most every 10
  s, like sync.
- Today: an answer summary under the share button, per-stop swap marks, and an answers sheet with
  "Swap it", "Keep it" and remove.
- "Swap it" = `edited(keeping:)` without the old stop, plus `inserting(alternate, at: index)`, then
  re-share. Recorded for undo.

### Mode 2: friends add what works for them

**Backend**

`GroupRequest` model:

| Field | Notes |
|---|---|
| slug | 10 random characters |
| owner | FK to Profile, CASCADE |
| places | JSON, ≤ 10 of `{id, name, neighborhood, kind, costText}`, in dollars as the plan page shows them |
| day | date |
| window_start, window_end | local times |
| time_zone | IANA name |
| answers_by | datetime |
| status | `open`, `closed` or `built` |
| shared_plan | FK, null until built, SET_NULL |

`GroupAnswer` model: request (FK, CASCADE), responder (hash, as above), name, budget (0 to 150),
free_from, free_until and stars (≤ 3 place ids). Unique on (request, responder).

- RLS migration for both tables.
- `GET /g/<slug>`:
  - while open, the form, built only from `<input type=range>`, `<input type=time>` and checkboxes,
    with no JavaScript;
  - once built, a 302 redirect to `/p/<plan slug>` (GI-7);
  - once closed, "This plan isn't taking answers any more".
- `POST /g/<slug>/answer`: the same protections as mode 1.
- Owner API:
  - `POST /api/plan-requests/` creates a request;
  - `GET /api/plan-requests/<slug>/` returns the request and all answers;
  - `POST /api/plan-requests/<slug>/close` closes it;
  - `DELETE /api/plan-requests/<slug>/` deletes it.
- `POST /api/shares/` takes an optional `request` slug, which sets `shared_plan` and
  `status = built` on that request.

**iOS**

- An "Ask friends what works" entry in the planner, which picks places, the day, the range and the
  deadline.
- A "Friends' answers" screen, and "Build our plan".
- `GroupInputs.combine(answers, organizer:, included:) -> (start, end, budget, priorities) or
  .clash([names])`. It's a pure function, tested on its own (GI-5, GI-6).
- `DayPlanner` gains `PlanCandidate.priority: Int` (default 0). Each drop rule (too late, over
  budget) first considers only the candidates with the lowest priority, then applies its current
  rule among them. With all priorities equal, behavior is unchanged, and the existing
  `DayPlannerTests` must still pass. Candidates are capped at the 7 with the most stars, so the
  exact search still applies.

### Mode 3: edit together

Revised November 22 after the G3 test-planning pass ([03-plan_g3-tests.md](03-plan_g3-tests.md)),
which found that the first design could lose or misattribute edits (MF-A to MF-G there).

**Backend**

`GroupPlan` model:

| Field | Notes |
|---|---|
| id | UUID |
| owner | FK to Profile, CASCADE (GE-10) |
| plan_id | the `DayPlan`'s own id. Unique with owner, so a retried create returns the same group |
| date | |
| data | JSON, the app's `DayPlan` encoding; ≤ 64 KB compact UTF-8, ≤ 20 stops |
| version | integer; goes up by one on each plan edit |
| members_version | integer; goes up on each join, leave or removal |
| invite_token | 22 random URL-safe characters, unique, can be replaced |
| created_at, updated_at | |

- `GroupMember`: id (UUID, the id the API uses for members, never the profile id), group (FK,
  CASCADE), profile (FK, CASCADE), display_name (the first word of the profile name at join, at
  most 30 characters; "Friend" when empty) and joined_at. Unique on (group, profile). The organizer
  is a member too.
- `GroupPlanEdit`, the edit log: group (FK, CASCADE), version, edit_id (UUID, unique per group),
  member_id (a plain UUID, not a foreign key), kind, stop_ids (JSON) and created_at. The latest 200
  per group are kept. Names are looked up from current members when read, so a deleted account's
  name never comes back.
- `GroupRemoval`: group (FK, CASCADE) and profile_id. Written when the organizer removes someone;
  joining checks it. Leaving yourself writes nothing, so you can rejoin.
- RLS on, with no policies, for every new table, as for every other table. Django connects as the
  tables' owner, so RLS doesn't apply to the API: isolation rests on the API's queries, and the
  isolation tests are the control.

API (signed in). Every request checks membership first; anyone else gets 404, never a 304 or a
409, which would show the group exists. Anonymous Supabase sessions get 403 on create and join.

- `POST /api/group-plans/` with `{date, plan}` returns `{id, version, inviteUrl}`.
- `GET /api/group-plans/` lists the caller's groups with their ETags.
- `GET /api/group-plans/<id>/` returns the plan and members (id, display name), `ETag:
  "<version>.<members_version>"` and `Cache-Control: private, no-cache`. `If-None-Match` is compared
  weakly; a match gives 304. Polls never run the retention purge.
- `PUT /api/group-plans/<id>/` with `{baseVersion, editId, edit: {kind, stopIds}, plan}`:
  - an `editId` already in the log answers 200 with that edit's version and changes nothing, so a
    retry after a lost response is safe;
  - a current `baseVersion` stores the plan, adds one to `version`, logs the edit and answers 200
    `{version}` with the new ETag;
  - otherwise 409 `{version, plan, members, edits}`, where `edits` are the logged edits after
    `baseVersion` (version, author's display name, kind, stop ids), with the ETag.
  - The plan must be an object whose `id` is the group's `plan_id`, with a `stops` list of unique
    stop ids; otherwise 400. Over the size limit, 413.
  - The plan's day ends at 4 AM New York time on the day after its date, so a night out stays
    editable. After that, PUT answers 400 "This plan's day has passed, so it can't be changed."
- `GET /api/group-plans/invites/<token>/` shows the organizer's first name, the date and the member
  count. `POST /api/group-plans/invites/<token>/join` joins (joining twice changes nothing). Both
  answer 404 when the group is full, the token was replaced, the date has passed, or the caller was
  removed.
- `POST /api/group-plans/<id>/invite` (organizer) replaces the token (GE-8).
- `DELETE /api/group-plans/<id>/members/<member id>/`: the organizer removes anyone else; a member
  removes themselves. The organizer can't leave (400 "End the plan instead").
  `DELETE /api/group-plans/<id>/` (organizer) ends the group.
- `GET /j/<token>`: a static page that says to open Plandit and paste the link, with the App Store
  link. It's the same page for every token, makes no database query, and has G0's CSP,
  `X-Robots-Tag: noindex` and `Referrer-Policy: no-referrer`.

Locking (MF-E), so writes never deadlock or fail at commit:

- Every group write locks the `GroupPlan` row first and checks membership again under that lock.
- Create and join also insert rows that reference the caller's profile, so they take the caller's
  profile lock before the group lock, the same order as account deletion and sharing.
- Account deletion locks the profile, then its shared plans and friends' input links (as today),
  then every group plan it owns or belongs to, by pk, before the cascade.
- Locking paths set a short `lock_timeout` and answer 503 "Try again" when it runs out.
- Group data is kept until 30 days after the date (GS-5).

**iOS**

- `GroupPlanStore`: an `@Observable` store for the member's groups, cached in a local file per
  user and not in the snapshot. The Swift member type is `GroupPlanMember`, because `GroupMember`
  already exists in `GroupInputs.swift`.
- `PlanEdit` edits stops by id (MF-A): add (with its stop id fixed in the edit), remove, move after
  a stop, set the trip between two stops, set one stop's status, and set one stop's times. Budget,
  extras and title edits are off in group plans for now. `apply(_:to:)` answers applied (with the
  plan), already applied, or no longer applies (with why). It never reuses Today's whole-list
  helpers, which drop or reset other people's changes.
- Each edit gets an `editId` and is applied locally, saved with the cache, then PUT one at a time
  with the base version. A network error retries with the same `editId`. On 409, the edit is
  applied to the server's plan and sent again. If it no longer applies, the app shows the plan and
  names who changed that stop, from the 409's `edits`. After 3 409s in a row it shows the latest
  plan with a message; an edit is never dropped silently.
- No Undo bar in group plans for now (MF-F): Today's Undo restores a whole copy of the plan, which
  would wipe other members' edits.
- Polling: every 15 s while a group plan is on screen and the app is active, and on foreground,
  with `If-None-Match` set to the ETag exactly as received and the URL cache bypassed. A poll older
  than the plan on screen is ignored.
- Today: a "Mine / <organizer>'s plan" control when both exist (GE-6), and members' initials.
- "Add a link" and the share extension recognize `…/j/<token>` and open the join sheet instead of
  place finding. The `/j/` page tells friends to open Saved and tap Paste a link (or +), so those
  visible labels must stay as they are, or the page changes with them.
- Rollover for a group plan happens after the same 4 AM cutoff the server uses.
- Rollover: when the date passes, add a `PastPlan` whose id is the group id, and the visited
  places, to the member's own snapshot, once per group (GE-9).
- A 404 on poll or PUT means the member was removed or the group ended: drop the cache and the
  pending edits, and say so.

### Shared pieces

- `plandit/core/public_forms.py`:
  - `responder_token(request, slug)` reads or creates the cookie and returns its hash.
  - `rate_limited(key, limit, window)` uses a `throttle` cache alias. That alias is the
    `DatabaseCache` (brief Q-4); its table is made in a migration with RLS.
  - `clean_first_name(value)` applies GS-4's rules and the blocklist.
- `plandit/core/retention.py`: `purge_expired()` deletes answers, requests and group plans past
  GS-5's limit. It runs at the start of every public answer POST and owner GET, with a cheap
  indexed delete, and also as `manage.py purge_expired` for a manual or scheduled run. There's no
  new cron service.
- `metrics.py`: the counts from the brief's analytics section.

## Flows

**Mode 1, a friend answers:**

1. The friend opens `/p/<slug>`. The page reads the `pa` cookie, if any, to show their own answer.
2. They submit the form. `POST /p/<slug>/answer` checks CSRF, the per-IP limit and the per-link
   cap, validates, upserts by responder hash and sets the cookie.
3. 303 back to the page, which shows the new count.

**Mode 1, the organizer reviews:**

1. Today appears. `GET /api/shares/<slug>/answers/` loads the summary and marks.
2. "Swap it" edits the plan, then `POST /api/shares/` re-shares it. The server drops swaps for
   removed stops.

**Mode 2:**

1. The organizer creates the request and gets `/g/<slug>`, which they send to friends.
2. Friends answer.
3. The organizer opens the answers, and the app combines them and plans.
   - On a clash, the app shows who and lets the organizer leave someone out.
4. The plan goes into Today. The app shares it with `request=<slug>`, and `/g/<slug>` now
   redirects to `/p/<plan slug>`.

**Mode 3, edit:**

1. A member edits locally, then `PUT` with `baseVersion`.
   - 200: done.
   - 409: apply the edit to the server's plan and PUT again, at most 3 tries, then show the latest
     plan with a message. A network error retries with the same `editId`.
2. Other members get the new version at their next poll (≤ 15 s while on screen).

**Mode 3, join:**

1. The member pastes or shares `/j/<token>` into Plandit.
2. `GET invites/<token>` loads the preview: "Join Maya's plan for Saturday? Your first name will
   show to the group."
3. `POST join`, then the group appears in Today on its date.

## Alternatives

- **Supabase Realtime or WebSockets for mode 3.** Instant updates, but it needs a client library
  (to be approved), RLS policies per member, and a second sync path. Polling every 15 s fits a day
  plan. Rejected for v1, and revisited if people edit at the same moment often.
- **Merging edits (CRDT) instead of compare-and-swap.** Overkill for a list of at most 20 stops
  edited by at most 8 people.
- **Storing group plans in `AppSnapshot`.** Impossible: snapshots are per person and last writer
  wins, so members would overwrite each other's whole app state.
- **Accounts for friends in modes 1 and 2.** It would remove the abuse surface, but it breaks the
  promise that friends need no app. Rejected; the limits in GS-2 to GS-5 cover it.
- **Planning mode 2 on the server.** The planner is Swift. Two planners would disagree. Rejected,
  as in suggested plans.
- **Free-text swap suggestions.** Friends could name any place, but that brings free text, places
  the organizer never saved, and a moderation burden. Rejected for picks from the organizer's own
  saves (GV-9).
- **JavaScript on the public pages.** Not needed; native form inputs cover the slider, times and
  stars. No JavaScript keeps the CSP strict.

## Failure modes

| Case | Behavior |
|---|---|
| The Supabase keep-awake job stops and Render sleeps | Links take 30 to 60 s again. GV-11 is measured before mode 1 ships; the job's health is Abraham's to watch. |
| A friend clears cookies or uses another browser | They can answer again as a new person. The organizer can remove the old answer. Accepted. |
| Someone floods a link | Per-IP limit, then the 50-answer cap per link. The organizer can stop sharing, which deletes everything. |
| The organizer edits the plan while friends answer | Answers stay. Swaps for removed stops are dropped. A friend's form posts against stop ids; unknown ids are ignored. |
| Mode 2 deadline passes with 0 answers | The organizer can still build with their own inputs, or delete the request. |
| Mode 2 windows don't overlap | GI-6: name the clash and let the organizer leave someone out. |
| Mode 3: two members edit the same stop at once | The second PUT gets 409. The edit applies again if it still makes sense, otherwise the author sees what changed. |
| Mode 3: a member is offline | Edits wait locally. On reconnect, PUT with the old base version. A 409 rebases the edit, or drops it with a message. |
| Mode 3: the organizer deletes their account | CASCADE ends the group. Members get 404 on their next poll and see "This plan ended". |
| An old app version opens a page with the new fields | The pages are server-rendered, and old apps never send stop ids, so swap buttons just don't show. |
| The throttle cache table is missing (deploy order) | It's created in the same migration as the models, so it can't be missing after `migrate`. |

## Security and privacy

- **Isolation.** Owner and member checks happen in the query (`filter(owner=request.user)`, or
  through `GroupMember`), never after fetching. Non-members get 404, so a slug's or id's existence
  isn't revealed. Tests try every endpoint as an outsider.
- **Tokens.** Slugs are 10 random characters, as #37's are. Invite tokens are 22 random
  characters from `secrets` and can be replaced. Responder cookies are 32 random bytes; only their
  SHA-256 hash is stored.
- **Public writes.** CSRF on every form, rate limits per IP and caps per link, strict validation,
  no free text but the first name, and a blocklist. Pages are `noindex`, `no-referrer`,
  `private, no-store`, with a CSP of `default-src 'none'`, `style-src 'self'` plus the Google font,
  `form-action 'self'` and `frame-ancestors 'none'`.
- **Row level security** on every new table, enforced by #41's test.
- **Personal data of people who aren't users.** First names, budgets and free times. Visible only
  to the organizer, except "in" first names on the page (brief Q-2). Deleted after 30 days
  (GS-5). Described in the privacy policy before submission (GS-6).
- **Members' names.** Only the first word of the profile name, with consent at join.
- **App Store.** The user-generated content answer is already "Yes". The report link, removing
  answers and removing members cover Guideline 1.2's report and block expectations. A removed
  member can't rejoin with the same link. Review Notes
  are updated in the rollout.
- **IP addresses** are used only as rate-limit keys in the cache, which expire within an hour. They
  aren't stored with answers.
