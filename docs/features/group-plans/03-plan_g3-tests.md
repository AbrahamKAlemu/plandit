# G3 test plan: mode 3, edit together (G3a backend, G3b iOS)

Independent test-planning pass required by 03-plan.md:138-141. Inputs: 01-brief.md (GE-1 to GE-10, GS-*), 02-architecture.md (mode 3 at lines 154-209, flows at 248-261, failure modes at 292-294), 03-plan.md:75-88 and 114-124. Existing code was read on `feat/group-requests-backend` (worktree g2a, 59c2ed2) and `feat/group-requests-app` (worktree g2b, 9e8fc9c).

## Dispositions (November 22, orchestrator)

All seven must_fix items are adopted, and [02-architecture.md](02-architecture.md) mode 3 is
revised to match:

- MF-A: `PlanEdit` edits stops by id and `apply` reports applied, already applied, or no longer applies.
- MF-B: PUT carries an `editId`, and the server keeps an edit log.
- MF-C: a 409 returns the edits since the base version, with authors.
- MF-D: the ETag includes `members_version`.
- MF-E: a fixed lock order, and no foreign key from the edit log to Profile.
- MF-F: no Undo in group plans for now.
- MF-G: a removed member can't rejoin; leaving yourself doesn't block you.

Notes adopted:

- N-2: tests go in `backend/tests/test_group_plans*.py`.
- N-6, N-7: polls never purge, and joins and PUTs are refused after the date.
- N-8: edits end with the plan's day in New York time.
- N-8b: the organizer can't leave.
- N-9: a unique owner and plan id.
- N-10: anonymous sessions get 403; an empty name shows as "Friend".
- N-11: members are addressed by member id.
- N-12: names are looked up when read.
- N-13: `lock_timeout`.
- N-19: budget, extras and title edits are off in group plans.

Accepted as they are:

- N-14: tokens appear in the access log.
- N-17: "full" and "replaced" look the same.

Left for G3b:

- N-5: a schema number.
- N-16: check-offs mark places as visited.
- N-18: a full 20-stop plan fits the size limit.
- N-20: catch-up prompts on every phone.

Priority: **P0** blocks merge, **P1** should land in the slice, **P2** nice to have.

## 0. Corrections to the brief's assumptions

- **RLS does not apply to the API.** Django connects as the role that owns the tables, and owners bypass RLS (backend/README.md:67-72, core/migrations/0008_enable_row_level_security_remaining.py:5-9, 0002:4-6). New tables get `ENABLE ROW LEVEL SECURITY` with **no policies**, which only denies `anon` and `authenticated` through PostgREST. #41's test checks just the `relrowsecurity` flag (tests/test_row_level_security.py:27-34). Isolation between users is enforced only in Django queries, so the isolation tests (section 1.1) are the real control. Test that there are *no* policies (RLS-3) rather than that policies exist.
- **Test location.** `pyproject.toml` has `testpaths = ["tests", "resolution/tests"]`. The plan's commands use `pytest plandit/groups/tests/` (03-plan.md:114-123), but the full lane (`cd backend && pytest`, 03-plan.md:134) would silently skip that folder. Put the tests in `backend/tests/test_group_plans*.py`, or add the folder to `testpaths`.

## 1. G3a backend tests

### 1.0 Harness and fixtures

- Clients: `organizer` (profile "Maya Lopez"), `member` ("Jordan Lee"), `outsider`, `removed` (joined, then removed), `other_member` (member only of group B), `anon` (no Authorization header), `deleted` (tombstoned token, as in tests/test_account_delete.py:172), `anon_supabase` (`make_token(is_anonymous=True)`, tests/conftest.py:21-49).
- `make_group(owner, members=[...], date=today, version=1)`: creates rows directly, like `make_request` (tests/test_requests.py:49).
- Race harness: generalize `friend_saves_while_owner_deletes` (tests/test_answer_races.py:40-73) and `another_session_is_waiting_for_a_lock` (same file, :28-37) into `first_holds_until_second_waits(monkeypatch, module, helper, first, second)`. Every race asserts `second_was_blocked is True`, that no thread is still alive after `WAIT_SECONDS*3`, and the exact statuses. Account deletions run with `with_supabase` parametrized, as at :89-93 and :113.
- **Seams G3a must expose for the barriers.** Each must be a module-level function called after the group row lock is taken and before commit: `_write_plan`, `_add_member`, `_remove_member`, `_replace_token`, `_end_group`, plus the new group-locking step inside `MeView._delete` (core/views.py:113-123). Precedents: tests wrap `share_views._mark_request_built` (tests/test_request_races.py:148-155) and `ShareAnswer.objects.update_or_create` (tests/test_answer_races.py:45-52).
- **Mutation check (P0, recorded in the PR):** run CON-1 and CON-4b once with the lock or membership re-check removed and confirm they fail. G2a did the same (04-progress.md:53-54).

### 1.1 Isolation (proves GS-1, GE-7)

ISO-1 (P0) is a parametrized matrix of endpoint × actor. Expected status for each:

| Endpoint | anon | deleted | outsider | removed | other-group member | member | organizer |
|---|---|---|---|---|---|---|---|
| `POST /api/group-plans/` | 401 | 401 | 201 | 201 | 201 | 201 | 201 |
| `GET /api/group-plans/` | 401 | 401 | 200, no G | 200, no G | 200, only B | 200, has G | 200, has G |
| `GET /<id>/` | 401 | 401 | 404 | 404 | 404 | 200 | 200 |
| `GET /<id>/` with `If-None-Match: "<v>"` | 401 | 401 | **404, never 304** | 404 | 404 | 304 | 304 |
| `PUT /<id>/` with a stale base | 401 | 401 | **404, never 409** (a 409 body contains the plan) | 404 | 404 | 409 | 409 |
| `PUT /<id>/` with the current base | 401 | 401 | 404, row unchanged | 404 | 404 | 200 | 200 |
| `GET invites/<token>/` | 401 | 401 | 200 | per MF-G | 200 | 200 | 200 |
| `POST invites/<token>/join` | 401 | 401 | 200 | per MF-G | 200 | 200, no duplicate | 200, no-op |
| `POST /<id>/invite` | 401 | 401 | 404 | 404 | 404 | 404, token unchanged | 200, new token |
| `DELETE /<id>/members/<other>/` | 401 | 401 | 404 | 404 | 404 | 404 | 204 |
| `DELETE /<id>/members/<self>/` | — | — | 404 | 404 | 404 | 204 | per N-8 |
| `DELETE /<id>/` | 401 | 401 | 404 | 404 | 404 | 404, group intact | 204 |
| `GET /j/<token>` | 200 | 200 | 200 | 200 | 200 | 200 | 200 |

Single tests:

| ID | Setup → action | Expected | Proves |
|---|---|---|---|
| ISO-2 P0 | GET and PUT on a random UUID vs on group G as an outsider | Same status, same body, no ETag header on either (no way to tell that G exists) | GS-1 |
| ISO-3 P0 | Member uses an upper-case UUID id; anyone uses a malformed id | Upper case → 200; malformed → 404, not 500. This repeats G1a's must-fix (04-progress.md:47, shares/urls.py:9) | GS-1 |
| ISO-4 P0 | Organizer of A calls `DELETE /A/members/<profile only in B>/` | 404; the B membership is intact | GS-1, GE-7 |
| ISO-5 P0 | Removed member sends GET with the ETag they held, then PUT | 404 and 404; the list no longer has the group | GE-7 |
| ISO-6 P1 | `anon_supabase` creates and joins | Whatever is decided in N-10, applied consistently | GE-2 |
| ISO-7 P1 | Every 200 or 409 body | No email and no profile ids, only display names and member ids (N-11) | GS-7 |

### 1.2 Versioning (proves GE-4, GE-5)

| ID | Setup → action | Expected |
|---|---|---|
| VER-1 P0 | Create | Version 1 and header `ETag: "1"` (quoted, exact) |
| VER-2 P0 | PUT with base = current | 200 `{version: v+1}`; `ETag: "v+1"`; stored data equals the sent plan |
| VER-3 P0 | PUT with base = v-1 | 409. Body: version v, the stored plan, the edits since the base with authors (MF-C), members. `ETag: "v"`. Database row unchanged, `updated_at` included |
| VER-4 P0 | PUT with base = v+1 | 409, never 200 |
| VER-5 P0 | `baseVersion` missing, null, `"3"`, `true`, `3.0` or `-1` | 400; row unchanged. A bool must not count as an int (pattern at core/views.py:215-216) |
| VER-6 P0 | GET with `If-None-Match` set to `"v"`, `W/"v"`, `"x", "v"` or `*` | 304, empty body, ETag and Cache-Control present. `"v-1"` or garbage → 200. Use weak comparison, because a proxy may weaken the ETag. Prefer Django's `get_conditional_response`, applied after the membership check |
| VER-7 P0 | GET with 200 | `Cache-Control: private, no-cache` (N-6) |
| VER-8 P0 | Join, leave, remove, then GET with the old ETag | 200 with the new members (MF-D) |
| VER-9 P1 | Five PUTs in a row | Versions 2 to 6, no gaps, never decreasing |
| VER-10 P0 (if MF-B) | Same `editId` resent with the old base | 200 with the same version, no bump, data unchanged. A different `editId` with a stale base → 409 |
| VER-11 P1 | A removes s2 at v2; B changes the time at v3; C sends a PUT with base v1 | The 409 lists v2 by A (remove s2) and v3 by B, so the app names A |
| VER-12 P1 | PUT and create | The caller's `AppSnapshot` version is unchanged (GE-6 on the server) |
| VER-13 P1 | GET with 304, after activity was recorded | At most 3 queries (`django_assert_max_num_queries`); no `purge_expired` call (activity writes at most once per 5 min, core/activity.py:20, 53-66) |

### 1.3 Concurrency (threaded, `django_db(transaction=True)`, proves GE-5, GE-7, GE-8, GE-10)

| ID | First request, which holds the lock in the seam | Second request | Expected |
|---|---|---|---|
| CON-1 P0 | Member A's PUT, holding in `_write_plan` | Member B's PUT with the same base | blocked; A 200; B 409 carrying A's plan; final version v+1. Mutation check required |
| CON-2 P0 | Join X at 7 members, holding in `_add_member` | Join Y | blocked; X 200; Y 404; 8 members (GE-1) |
| CON-3a P0 | Member's PUT, holding in `_write_plan` | Organizer removes that member | blocked; PUT 200; DELETE 204; member's next GET 404 |
| CON-3b P0 | Organizer's removal, holding in `_remove_member` after the delete | That member's PUT | blocked; DELETE 204; **PUT 404**; data and version unchanged. Proves membership is re-checked under the lock. Mutation check required |
| CON-4a P0 | Join with the current token, holding in `_add_member` | Organizer replaces the token | blocked; join 200; replace 200; member kept; old token now 404 (GE-8) |
| CON-4b P0 | Replace, holding in `_replace_token` | Join with the old token | blocked; replace 200; join 404; no member row |
| CON-5a P0 | Member's PUT | Organizer `DELETE /api/me/`, with and without Supabase | blocked; PUT 200; delete 204; no group or member rows; profile gone (GE-10) |
| CON-5b P0 | Organizer's deletion, holding after it locks the group plans | Member's PUT | blocked; 204; PUT 404 |
| CON-6a/b P0 | Join / organizer's deletion, in both orders | The other | No IntegrityError at commit (the bug class G1a and G2a fixed, 04-progress.md:47-55); 200 then gone, or 404 |
| CON-7 P0 | Member's PUT from a second device with the same token (as tests/test_request_races.py:138-139) | That member's `DELETE /api/me/`, both orders | Both finish; no 500 and no deadlock; PUT in {200, 401, 404}; delete 204; nothing refers to the profile; group intact (MF-E) |
| CON-8 P1 | Organizer ends the group (`_end_group`), against a PUT and against a join, both orders | — | {204, 200} then GET 404, or {204, 404} |
| CON-9 P1 | Member leaves | Organizer removes the same member | {204, 404}, no 500 |
| CON-10 P2 | `purge_expired` on an expired group | A join or PUT | The join is refused by the date guard, not by timing; the request hosting the purge doesn't return 500 (N-7) |
| CON-11 P2 | Two creates with the same plan id (if N-9 is adopted) | — | One row; 201 and 200 |

### 1.4 Invites and the `/j/` page (proves GE-1, GE-2, GE-8, GS-3)

| ID | Test | Expected |
|---|---|---|
| INV-1 P0 | Create | `inviteUrl` = `<base>/j/<token>` with the token matching `[A-Za-z0-9_-]{22}`; tokens differ between groups. Use its own base setting, as `REQUEST_BASE_URL` does (plans/request_views.py:64-68) |
| INV-2 P0 | Preview | Exactly the organizer's first name, the date and the member count: no stops, no member names |
| INV-3 P0 | Join "Jordan Lee" | Member row with `display_name` "Jordan"; GET then 200 |
| INV-4 P1 | Display name from an empty name, spaces only, one 120-character word, or emoji | Never empty in GET (a decided fallback); within the length cap (N-10) |
| INV-5 P0 | Join twice; join as an existing member when the group is full | One row; 200 each time (not 404) |
| INV-6 P1 | Organizer opens their own invite | 200, no-op |
| INV-7 P0 | Replace the token twice | Only the latest preview and join work; earlier ones 404; members intact |
| INV-8 P0 | Full group, new user | Preview 404 and join 404 (02-architecture.md:182-184) |
| INV-9 P0 | Removed member rejoins with the same token | 404, per MF-G |
| INV-10 P0 | `GET /j/` with a valid, a replaced and a random token | Byte-identical bodies (the page shows no group details and reveals nothing); `django_assert_num_queries(0)` |
| INV-11 P0 | `/j/` headers | `Content-Security-Policy` == `PUBLIC_PAGE_CSP` (core/public_forms.py:240-252); `X-Robots-Tag: noindex`; **`Referrer-Policy: no-referrer`** (the page links to the App Store and the token must not leak) |
| INV-12 P1 | `/j/` HTML | Fits its policy: no inline style or script, own static CSS only (as tests/test_shares.py:174-189); App Store link and "Report this page" link without the token in the mailto (unlike `/p/`, tests/test_shares.py:192-199) |
| INV-13 P1 | `POST /j/x` | 405; a malformed or overlong token gives the 404 page with the CSP |
| INV-14 P1 | Preview or join for a group past its date | 404 (N-7) |

### 1.5 Limits and validation (proves GE-1, GE-6)

| ID | Test | Expected |
|---|---|---|
| LIM-1 P0 | Ninth member | 404; still 8 |
| LIM-2 P0 | Compact UTF-8 JSON of exactly 65,536 bytes, then 65,537, measured as at core/views.py:261; for create and PUT | Accepted, then 413 |
| LIM-3 P0 | `Content-Length` above the limit plus a margin | 413 without parsing the body (core/views.py:249-254) |
| LIM-4 P0 | 20 stops, then 21 | Accepted, then 400; version unchanged |
| LIM-5 P0 | Plan not an object; `stops` not a list; a stop without an id; duplicate stop ids; `legs`, `date`, `title` or `budget` missing | 400 (N-4) |
| LIM-6 P0 | PUT whose `plan.id` differs from the stored plan's | 400. Catches the app writing the personal plan into the group (GE-6) |
| LIM-7 P1 | NaN or Infinity in the plan | 400, not 500 (jsonb can't store NaN) |
| LIM-8 P1 | Date in the past, more than 366 days ahead, or not ISO | 400 |
| LIM-9 P2 | Plan with Unicode names | Round-trips unchanged |

### 1.6 Cascades and retention (proves GE-7, GE-9, GE-10, GS-5)

| ID | Test | Expected |
|---|---|---|
| CAS-1 P0 | Organizer deletes the account, with and without Supabase | Group and every member row gone; members' GET 404; list empty |
| CAS-2 P0 | Member deletes the account | Only that membership is gone; plan and version intact; ETag changes; their name appears in no GET or 409 body (N-12) |
| CAS-3 P0 | A deleted account's token on any group endpoint | 401 "Account deleted." (core/auth.py:98-101) |
| CAS-4 P0 | Organizer ends the group | 204; members' GET 404; old token preview 404 |
| CAS-5 P1 | Member leaves | 204; organizer sees count−1; leaving again 404 |
| CAS-6 P0 | Groups dated today−30 and today−29, then purge | today−30 deleted with its members; today−29 kept (cutoff rule at core/retention.py:53-58) |
| CAS-7 P1 | Retention rules | `retention.RULES` includes the group plan's date with 30 days (registered in AppConfig.ready, like plans/apps.py:15) |
| CAS-8 P0 | GET the day after the group's date | 200 until the purge, so members can roll over (GE-9) |
| CAS-9 P1 | Profile that organizes G1 and is a member of G2 deletes the account | G1 gone; G2 intact without them |

### 1.7 Row level security (proves GS-1)

| ID | Test | Expected |
|---|---|---|
| RLS-1 P0 | Each new table | `relrowsecurity` is true (as tests/test_requests.py:81-85) |
| RLS-2 P0 | `tests/test_row_level_security.py` | Passes unchanged |
| RLS-3 P0 | `pg_policies` for the new tables | No rows |
| RLS-4 P0 | Migrate forward, back, forward; `makemigrations --check` | All clean |
| RLS-5 P2 | Create a test role without BYPASSRLS, `GRANT SELECT`, `SET LOCAL ROLE` | 0 rows visible |

### 1.8 Contract and metrics

| ID | Test | Expected |
|---|---|---|
| CTR-1 P0 | Every method and path the G3b client calls, with its exact trailing slash (`invites/<t>/join` vs `join/`) | The expected status; never a 301 on POST (APPEND_SLASH) |
| MET-1 P1 | Metrics | Counts of groups with 2+ members and edits per group; no names (01-brief.md:229-235) |
| GS-7 | Reviewer | Greps that group plans are read only by their views, metrics, retention and account deletion |

## 2. G3b iOS tests

### 2.0 Seams that must be injectable

- **HTTP.** Two layers:
  - `HTTPTransport` (Services/AuthenticatedAPI.swift:56-59) with the existing `FakeTransport` (PlanditTests/Support/FakeTransport.swift:5-57). Use this for the client's status mapping: 200, 304, 404, 409, 413, network error, and 401 refresh.
  - A `GroupPlanServing` protocol, shaped like `PlanRequesting` (Services/Sync/PlanRequestClient.swift:5-16). Its fake actor can hold and release a response (pattern: `holdNext()`/`release()` at PlanditTests/Support/AskFriendsFixtures.swift:71-72), simulate other members' writes, and return 304, 409 or 404.
- **Clocks.**
  - Polling clock: an injected `any Clock<Duration>` or a `sleep` closure. Don't call `Task.sleep` directly: SyncCoordinator only injects a Duration (SyncCoordinator.swift:255-262), which can't test a 15 s cadence.
  - `now: () -> Date` and a `Calendar` with a fixed TimeZone for `PlanEdit.apply` and rollover. `inserting` depends on `now` (Models/PlanEditing.swift:39, 87); rollover uses `Calendar.current` (PlanditStore.swift:473-474); `AppClock` is a static (Models/AppClock.swift:5-16).
- **Other seams:**
  - A UUID factory for `editId`s.
  - The cache file directory (temp dir per test, keyed by user id, as in Services/Persistence.swift:23-27).
  - The "plan on screen" and "app active" signals, as methods.
  - `RouteProviding` (PlanditStore init, :114), so trip edits never call MapKit.
  - A message sink to assert copy such as "Maya removed that stop".

### 2.1 `PlanEdit.apply(_:to:now:calendar:) -> .applied(DayPlan) | .alreadyApplied | .noLongerApplies(reason)` (proves GE-3, GE-5)

Each edit is tested against a server plan where:

- (a) its stop was removed;
- (b) its stop moved;
- (c) its stop changed: done, now, or a new time;
- (d) another stop was added;
- (e) another stop was removed;
- (f) the edit was already applied;
- (g) nothing else changed (the result must equal the local result).

| Edit | Key cases (P0 unless marked) |
|---|---|
| add(candidate, stop id fixed in the edit) | (d) and (e) insert it and keep everything else. (f) stop id already present → alreadyApplied, no duplicate. Plan already at 20 → noLongerApplies(full). All stops done → appended at the end. The id stays the same through the rebase (PlanEditing.swift:72-73) |
| remove(id) | (d) **the added stop is kept**: regression for `edited(keeping:)` dropping it (PlanEditing.swift:166-177, used by PlanditStore.swift:931-932). (a) → noLongerApplies(stopGone, by: author) or alreadyApplied, as decided. (b) removed from its new position |
| move(id, after:) | (a) nil. (c) done or now → nil (`firstMovableIndex`, PlanEditing.swift:7-9). (d) and (e) apply relative to the anchor. Anchor removed → decided fallback. **Regression:** a whole-list reorder against a plan with one extra stop must not silently do nothing (`reordered` returns self, PlanEditing.swift:155-156) or drop the stop |
| setTravel(from, to, mode, minutes, cost) | Keyed by the stop pair, not the leg id: `setLeg` matches leg ids (DayPlan.swift:310-316) and `relinkLegs` regenerates them (PlanEditing.swift:13-18). Pair no longer adjacent, or a stop removed → nil. Still adjacent after a reorder → applies, and later stops shift by the server's leg minutes |
| setStatus(id, arrive/complete/leave) | (a) nil. (f) already done → alreadyApplied. **Two check-offs at once:** complete(s1) rebased onto a plan where s3 was completed must not put s2 or s3 back to planned. The current `setStatuses` sets every status by position (PlanditStore.swift:1528-1533; arrive/complete/leave at :957-976) |
| setTime(id, start, duration, moveLater) | (a) and (c)-done → nil, not a silent no-op (DayPlan.swift:332). (b) applies at the new position; later stops shift from there |
| markOverdueDone / startRestFromNow (P1) | Two members' "Start from now" rebased → the day shifts once (recomputed when applied, PlanEditing.swift:124-145) |
| budget, extras, cost, title (P1) | Either `PlanEdit` cases with tests, or disabled in group mode, checked by a UI test (PlanditStore.swift:411-467) |

### 2.2 The rebase loop (`GroupPlanStoreTests`, proves GE-5)

| ID | Scenario | Expected |
|---|---|---|
| RB-1 P0 | One edit, 409 once | Second PUT has base = the server's version and plan = `apply(edit, serverPlan)`; then 200; local plan = what was sent; version stored |
| RB-2 P0 | 409 three times in a row | Exactly 3 PUTs; then the latest plan **and a visible message**; never a silent drop (N-3) |
| RB-3 P0 | 409 where the stop was removed | No second PUT; "Maya removed that stop" names the author from the 409's edit list (MF-C), not the latest editor; local plan = the server's |
| RB-4 P0 | Two pending edits: E1 out, E2 made meanwhile | E2 isn't sent until E1 resolves; E2's base = E1's version; both land in order. On E1 409: rebase E1, then apply E2 on top |
| RB-5 P0 | E1 and E2 touch a stop someone removed | Both dropped with one message. An unrelated E3 still lands |
| RB-6 P0 | A poll returns version v+1 while the PUT is out | Screen shows `serverPlan + pending edits` (the edit doesn't flicker away); the in-flight 409 is handled |
| RB-7 P0 | A stale poll (v) arrives after PUT 200 (v+1) | Ignored; the version never goes backwards (same idea as the change counter at PlanditStore.swift:46-48, 1146-1155) |
| RB-8 P0 | Network error on the PUT | Edit stays pending; retried with the same `editId`; if the server had applied it → no duplicate stop (MF-B; transport errors become `.network`, PlanditAPIClient.swift:100-104) |
| RB-9 P0 | 404 on the PUT | Group dropped; pending edits discarded; removed-from-plan message; no retry |
| RB-10 P1 | 400 or 413 on the PUT | Edit dropped with a message; plan back to the server's; no loop |
| RB-11 P1 | A 409 or 200 body that doesn't decode | Keep the last good cache; never PUT over it; no loop (same idea as SyncCoordinator `isReadOnly`, :82-83, 135-139) |

### 2.3 Polling (proves GE-4)

| ID | Test | Expected |
|---|---|---|
| POL-1 P0 | Plan on screen, app active, manual clock | GET at appear, at 15 s and at 30 s; none at 14.9 s |
| POL-2 P0 | Server answers 304 | No redraw: the observation of `plan` doesn't fire |
| POL-3 P0 | 200 with v+1 | Plan replaced; ETag stored exactly as received, including `W/`; the next request sends it |
| POL-4 P1 | 200 with the same version (URLCache turned a 304 into a 200) | No redraw; requests use `.reloadIgnoringLocalCacheData` |
| POL-5 P0 | Plan off screen or app in the background; then foreground | No polls in the background; an immediate GET on foreground ("when the app opens") |
| POL-6 P0 | A GET is held past 15 s | No overlapping second poll |
| POL-7 P1 | Network error or 5xx | Cache kept; polling continues with backoff |
| POL-8 P1 | Several groups | Only the group on screen polls; the list refreshes on foreground and picks up groups joined on another device |

### 2.4 Removed member or ended group (proves GE-7, GE-10)

| ID | Test | Expected |
|---|---|---|
| REM-1 P0 | Poll gets 404 | Group removed from the store **and the cache file**; Today switches to "Mine"; the message shows once |
| REM-2 P0 | 404 on one group | Other groups untouched |
| REM-3 P1 | Group missing from the list | Dropped |
| REM-4 P0 | Sign-out or account deletion | Group cache files deleted; the store is closed with no late writes (pattern: `PlanditStore.close`, :195-200) |
| REM-5 P1 | Two accounts on one phone | Caches keyed by user id; never mixed |

### 2.5 Today switcher (proves GE-6)

| ID | Test | Expected |
|---|---|---|
| SW-1 P0 | After any group edit | `PlanditStore.today` encodes byte-identical; `onChange` doesn't fire (:76); no snapshot push |
| SW-2 P0 | Personal edit | No group PUT. Group edit → no `/p/` update (`scheduleShareUpdate`, :1062) |
| SW-3 P0 | Undo after a poll brought in a remote change | The remote change survives (MF-F; `PlanUndo` holds a whole plan, PlanditStore.swift:1482-1516) |
| SW-4 P1 | Switcher | Shown only when both plans exist; handles two groups on the same day (N-15); keeps the selection |
| SW-5 P1 | Group stops whose `sourcePostID` isn't in this member's saves | Render fine. Adding a place another member already added is decided, since `isInToday` matches by post (:270-272) |

### 2.6 Rollover (proves GE-9)

| ID | Test | Expected |
|---|---|---|
| RO-1 P0 | Date passes (injected `now`, fixed TimeZone) | One `PastPlan` with **id == the group id** (PastPlan.id is `UUID()` today, Models/UserProfile.swift:34-35); visited places added; `today` untouched |
| RO-2 P0 | Rollover runs twice (launch, then foreground) | Still one |
| RO-3 P0 | Device A rolls over and pushes; B pulls | B doesn't add another: `replace(with:)` swaps everything (PlanditStore.swift:155-170) and the sync is last writer wins (SyncCoordinator.swift:198-223) |
| RO-4 P0 | Both devices roll over before syncing, then push and pull | Exactly one `PastPlan` for that group on both |
| RO-5 P1 | Pending edit at the end of the day | Decided: the server-acknowledged plan plus pending edits, or send first (N-8) |
| RO-6 P1 | Group returns 404 before rollover | Decided: no `PastPlan`, or one from the cache |
| RO-7 P1 | Group for a later date | Not rolled over |
| RO-8 P2 | Sync is read-only | Rollover kept locally; no duplicate after the app is updated |

### 2.7 Offline and relaunch (proves GE-5)

| ID | Test | Expected |
|---|---|---|
| OFF-1 P0 | Offline edit | Shown locally; the pending edit (`PlanEdit`, base, `editId`) is in the cache file; on reconnect PUT with the original base, then 409 → rebase |
| OFF-2 P0 | App killed with a pending edit | Relaunch replays it with the same `editId` |
| OFF-3 P0 | Killed after the PUT went out but before the 200 was saved | Replay → the server says already applied → no duplicate (MF-B) |
| OFF-4 P1 | Corrupt cache file | Start empty, fetch the list, no crash |
| OFF-5 P1 | Removed while offline | The pending PUT gets 404 → dropped with the message |

### 2.8 Join by link and UI test (proves GE-2)

| ID | Test | Expected |
|---|---|---|
| JN-1 P0 | "Add a link" and the share extension with `https://plandit.app/j/<t>` or `<api host>/j/<t>` | Join sheet, not place finding; `/p/`, `/g/` and social links unchanged |
| JN-2 P1 | Preview gets 404 | "This invite doesn't work any more" (full and replaced look the same, N-17) |
| JN-3 P1 | Join twice; organizer pastes their own link | No duplicate group |
| UI-1 P0 | DEBUG `FakeGroupPlanServer` (like `FakeShareAnswers`, ShareAnswersClient.swift:36-76), launch-arg scripted: Maya removes stop 2 at the next poll while the UI user edits stop 2 | The message names Maya; an edit to stop 3 lands; 03-plan.md:87-88 |

Rename the new member type: `GroupMember` already exists as an enum in Models/GroupInputs.swift:4.

## 3. Gaps and risks

| ID | Tag | Issue | Fix or test |
|---|---|---|---|
| MF-A | **must_fix** (G3b) | `PlanEdit` "of the edits Today already supports" (02-architecture.md:195-197) would wrap helpers that lose concurrent work. `edited(keeping:)` drops stops added since (PlanEditing.swift:166-177). `reordered` returns `self` on a different stop list (:155-156). `setLeg` is keyed by leg ids that `relinkLegs` regenerates (DayPlan.swift:311; PlanEditing.swift:13-18). `setStatuses` cascades by position (PlanditStore.swift:1528-1533). `setTime` silently does nothing (DayPlan.swift:332). This breaks GE-5's "both apply when they touch different stops" | Define by-intent edits keyed by stop id: remove(id), move(id, after:), status per stop that never moves a done stop back while rebasing, travel by stop pair. `apply` returns applied, alreadyApplied or noLongerApplies(reason). Section 2.1 |
| MF-B | **must_fix** (contract) | PUT isn't idempotent. A response lost after the commit, followed by a retry with the old base, returns 409 with the user's own edit already in the plan. The rebase then duplicates an add, or blames someone else for a remove. The client can't tell, because transport errors all become `.network` (PlanditAPIClient.swift:100-104) | PUT carries `editId`; the server keeps a small `GroupPlanEdit(group, version, edit_id, member, kind, stop_ids)` log and answers 200 with the original version for a known `editId`. Purge the log with the group. VER-10, RB-8, OFF-3 |
| MF-C | **must_fix** (contract) | The 409 returns `updatedBy` (02-architecture.md:179-181), but `GroupPlan` has no column for it (:158-168). When more than one version has passed, the latest editor is not necessarily who removed the stop, so "Maya removed that stop" can name the wrong person (GE-5) | The 409 returns the edits since `baseVersion` (version, author's display name, kind, stop ids) from MF-B's log, plus `members` and an `ETag` header. Resolve names when reading, not stored as copies (N-12). VER-3, VER-11, RB-3 |
| MF-D | **must_fix** (contract) | `ETag: "<version>"` (02-architecture.md:177-178), but join, leave and remove don't bump `version`. A poll gets 304, initials stay stale (GE-3), and a removed member keeps showing to everyone until the next plan edit | Add a `members_version` and send `ETag: "<version>.<members_version>"`; the compare-and-swap uses only `version`. VER-8 |
| MF-E | **must_fix** (G3a) | Django foreign keys are checked at commit (shares/views.py:89-97 explains this), and `MeView._delete` locks the profile first (core/views.py:105-123). With `updated_by` as a foreign key to Profile, or a join that isn't serialized with the cascade, deletion and a PUT or join can deadlock or fail at commit with a 500. That happens *after* Supabase has already deleted the auth user (core/views.py:96-110) | (1) Every group write takes the GroupPlan row lock first and re-checks membership under it. (2) `_delete` locks the account's group plans, owned and member-of, ordered by pk, before `locked.delete()`. (3) No foreign key from GroupPlan to Profile for the last editor. CON-5 to CON-7 |
| MF-F | **must_fix** (G3b) | Today's Undo restores a whole saved plan (`PlanUndo.plan`, PlanditStore.swift:1482-1516). In a group plan that reverts other members' edits | Undo = the inverse `PlanEdit` going through PUT and rebase, or no Undo in group plans for v1. SW-3 |
| MF-G | **must_fix** (G3a) | A removed member can rejoin with the same token. The architecture says removing members covers Guideline 1.2's block expectation (02-architecture.md:315-317) | Replace the token automatically on removal, or keep a list of removed profiles that join checks. INV-9 |
| N-1 | note | RLS premise (section 0) | RLS-1 to RLS-3 |
| N-2 | note | Test folder isn't collected (section 0) | — |
| N-3 | note | "At most 3 tries, then show the latest plan" (02-architecture.md:252-253) drops an edit without telling anyone | RB-2 |
| N-4 | note | One bad client's plan JSON can break decoding for every member | Server shape checks (LIM-5, LIM-6); the app keeps its last good copy (RB-11) |
| N-5 | note | Older apps drop unknown keys and PUT the plan back | Later, send a `schema` number and have the server reject a lower one; can be added without breaking anything |
| N-6 | note | URLCache and proxies | `Cache-Control: private, no-cache`; weak ETag comparison; the client echoes the ETag exactly. VER-6, VER-7, POL-4 |
| N-7 | note | `purge_expired` deletes without locks (core/retention.py:33-37) and runs inside unrelated requests | Don't purge on the 15 s poll (VER-13); refuse join and PUT after the group's date; CON-10 |
| N-8 | note | Whether edits are allowed after the date isn't defined (rollover consistency) | Decide a cutoff in New York time (settings.py:229) |
| N-9 | note | Create isn't idempotent: a double tap or a retry makes two groups and two links | `UniqueConstraint(owner, plan_id)`, like SharedPlan (shares/models.py:31-32). CON-11 |
| N-10 | note | Anonymous Supabase profiles (core/models.py:66) and empty profile names give empty initials | Decide; ISO-6, INV-4 |
| N-11 | note | `DELETE members/<profile>` exposes Supabase auth ids to members | Use the GroupMember id |
| N-12 | note | A stored `updatedBy` name outlives the member's account deletion | Resolve names when reading; CAS-2 |
| N-13 | note | 2 gunicorn workers: two requests waiting on locks stall the API | `SET LOCAL lock_timeout` on locking paths |
| N-14 | note | Invite tokens appear in Render's access log (the brief accepts this for slugs, 01-brief.md:237-238) but they grant edit access | Accept, or replace tokens on a schedule |
| N-15 | note | Same-day multiple groups need more than two switcher options | SW-4 |
| N-16 | note | A check-off marks places as visited for every member (GE-9); the stop note "Added from your saved … post" (DayPlanner.swift:36) shows to everyone | Product and copy call |
| N-17 | note | "Full" and "token replaced" are both 404 | The app can't explain which |
| N-18 | note | No proof yet that a 20-stop plan from the app's encoder fits in 64 KB | iOS test: encode a maximal plan; assert under 56 KB |
| N-19 | note | Budget, extras, cost and title edits aren't in the `PlanEdit` list | Section 2.1, last row |
| N-20 | note | Catch-up prompts fire on every member's phone | Must be idempotent when rebased; section 2.1 |
| N-8b | note | Organizer leaving or removing themselves isn't defined | 400 "End the plan instead", or treat it as ending the group |

## 4. Minimum set to ship G3a

1. ISO-1 (the full matrix), ISO-2 and ISO-3, including **outsider stale PUT → 404, never 409** and **outsider conditional GET → 404, never 304**.
2. CON-3b: a removal that commits first makes the removed member's PUT 404 (membership checked under the lock), with the mutation check.
3. VER-2, VER-3, VER-4 and VER-5, plus CON-1 (concurrent PUTs give one 200 and one 409, with the mutation check).
4. VER-6 (304 for `"v"` and `W/"v"`) and VER-8 (ETag changes when members change).
5. CON-2 and LIM-1 (8-member limit, sequential and racing).
6. INV-7 and CON-4b (a replaced token gives 404 to preview and join, including mid-join).
7. CON-5a/b, CON-6a/b and CON-7 (account deletion against PUT and join: 204, no rows, no 500, no deadlock), plus CAS-1 and CAS-2.
8. LIM-2, LIM-4, LIM-5 and LIM-6 (size, stop count, shape, plan id).
9. VER-10 (idempotent retry), if MF-B is adopted, which I recommend.
10. RLS-1 to RLS-4.
11. INV-10 and INV-11 (`/j/` identical for any token, CSP, no-referrer, noindex) and INV-13.
12. CAS-6 and CAS-8 (purge boundary; GET still works after the date).
13. CTR-1 (exact client paths and slashes).
14. VER-12 (group writes never touch `AppSnapshot`).
