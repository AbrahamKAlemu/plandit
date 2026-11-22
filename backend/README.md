# Plandit API

Django 6 + Django REST Framework on PostgreSQL. Deployed environments use **Supabase** for both
the database (Postgres) and sign-in (Supabase Auth). Django owns the schema through migrations
and enforces every authorization rule; Supabase's auto-generated Data API is locked out of the
Plandit tables (see "Row level security" below).

```
backend/
  config/            settings, urls, wsgi/asgi, test settings
  plandit/
    core/            Supabase JWT auth, Profile, /api/me (+ snapshot, events, delete), activity, /api/metrics, RLS migrations
    places/          Place catalog + Manhattan seed fixture
    saved/           Saved TikToks/Reels/links and the extraction pipeline (oEmbed -> place matcher)
    plans/           Day plans, stops, travel legs; friends' input links: /api/plan-requests/ and the public /g/ page
    waitlist/        Public signup endpoint used by website/
    shares/          Shared plan links: /api/shares/, the public /p/ page, and friends' answers on it
    groups/          Group plans members edit together: /api/group-plans/ and the public /j/ invite page
  tests/             pytest (runs against a real Postgres)
  Dockerfile         production image: migrate, then gunicorn
  docker-compose.yml local Postgres only
```

## Run locally

```sh
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
cp .env.example .env
# Generate a local password, then put it in POSTGRES_PASSWORD in .env:
python -c "import secrets; print(secrets.token_urlsafe(24))"
docker compose up -d                  # Postgres 16 on localhost:5433
python manage.py migrate
python manage.py loaddata manhattan_places
python manage.py runserver 8001       # the website's dev server uses 8000
```

- `POSTGRES_PASSWORD` is required for local development. Django constructs the loopback-only
  database URL from it; deployed environments must provide `DATABASE_URL` instead.
- Tests: `pytest` (needs the compose Postgres; it creates its own `test_plandit` database).
  The test settings refuse a `DATABASE_URL` whose host contains `supabase` so a production URL
  in `.env` is never used for tests; set `PLANDIT_ALLOW_REMOTE_TEST_DB=1` to override on purpose.
- Lint: `ruff check . && ruff format --check .`
- Admin: `python manage.py createsuperuser`, then http://localhost:8001/admin/.
- Health: `curl http://localhost:8001/api/health/`

## Supabase setup

1. Create a project at supabase.com. Pick a region close to the API host.
2. **Database.** Dashboard → Connect → ORMs → Django, or copy the *Session pooler* URI. Put it in
   `DATABASE_URL` with `?sslmode=require`. Use port 5432 (session pooler or direct) for a long-lived
   server; port 6543 (transaction pooler) is for serverless, and the settings switch off server-side
   cursors and prepared statements automatically when they see it.
3. **Auth.** Set `SUPABASE_URL=https://<project-ref>.supabase.co`. Projects using JWT signing keys
   (the default for new projects) need nothing else: public keys are fetched from
   `/auth/v1/.well-known/jwks.json` and cached. Projects still on the legacy shared secret also
   set `SUPABASE_JWT_SECRET` (Project Settings → JWT Keys → Legacy JWT secret).
4. Enable anonymous sign-ins under Authentication → Providers. The iOS TestFlight build uses one
   anonymous user per installation so extraction requests can be authenticated and rate limited
   without adding onboarding.
5. Run once against the Supabase database:
   ```sh
   python manage.py migrate
   python manage.py loaddata manhattan_places
   ```

### Row level security

`core.0002_enable_row_level_security` turns on RLS for every Plandit table and adds no policies.
Django connects as the role that created the tables, and table owners bypass RLS, so the API is
unaffected. The `anon` and `authenticated` roles used by Supabase's Data API (PostgREST) get no
rows. If you want belt and braces, also remove `public` from *Exposed schemas* under API settings.

### How the iOS app authenticates

The app signs in anonymously through the Supabase Auth REST API, stores the refresh token in the
iOS Keychain, refreshes expired sessions, and sends the access token on extraction requests:

```
Authorization: Bearer <session.accessToken>
```

The first authenticated request creates the `Profile` row from the token's `sub`, `email`, and
`user_metadata.full_name`. Every request also syncs `is_anonymous` and `app_metadata.provider`,
sets `signed_up_at` the first time a non-anonymous token is seen, and records the account as
active today (at most one write per 5 minutes). Tokens are verified locally; no call to Supabase
per request.

Accounts (email + password, Sign in with Apple) sync the app's whole local store through
`/api/me/snapshot/` and report `link_saved`, `place_saved`, `plan_built` and `suggestion_used`
through `/api/me/events/`. A **real user** is a non-anonymous profile with `activated_at` set,
which happens on the first `plan_built` event or the first snapshot containing a plan with stops.

## Deploy

The image runs migrations and then gunicorn on `$PORT`. It works unchanged on Render, Fly.io,
Railway, or any container host.

```sh
docker build -t plandit-api backend
docker run -p 8000:8000 --env-file backend/.env plandit-api
```

Required environment in production:

| Variable | Value |
|---|---|
| `DJANGO_DEBUG` | `0` |
| `DJANGO_SECRET_KEY` | long random string (`python -c "import secrets;print(secrets.token_urlsafe(64))"`) |
| `DJANGO_ALLOWED_HOSTS` | `api.plandit.app` |
| `DATABASE_URL` | Supabase pooler URI with `?sslmode=require` |
| `SUPABASE_URL` | `https://<project-ref>.supabase.co` |
| `SUPABASE_JWT_SECRET` | only for legacy HS256 projects |
| `CORS_ALLOWED_ORIGINS` | `https://plandit.app,https://www.plandit.app` |
| `ENSEMBLEDATA_ENABLED` | `1` to enable social evidence extraction; `0` is the kill switch |
| `ENSEMBLEDATA_API_TOKEN` | server-side provider token; never put this in the iOS build |
| `SOCIAL_EVIDENCE_THROTTLE_RATE` | authenticated per-user limit, default `100/day` |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase service-role key (Project Settings → API keys, secret); used only to delete auth users on `DELETE /api/me/`. Without it, account deletion removes Plandit data only |
| `APPLE_TEAM_ID`, `APPLE_SIGNIN_KEY_ID`, `APPLE_SIGNIN_PRIVATE_KEY` | Sign in with Apple token revocation on `DELETE /api/me/` (App Store guideline 5.1.1(v)): the team ID (`9A6H44778K`), the Key ID of a Sign in with Apple key, and that key's `.p8` contents (literal `\n` escapes accepted). `APPLE_CLIENT_ID` defaults to `com.plandit.app`. Without them, deletion still completes and the revocation is skipped with a warning |
| `METRICS_PUBLIC` | default `1`: `GET /api/metrics/` (counts only) needs no key. `0` requires `METRICS_API_KEY` |
| `METRICS_API_KEY` | shared secret for `GET /api/metrics/` when `METRICS_PUBLIC=0`; then an empty key turns the endpoint off. The Render blueprint generates one |
| `SHARE_BASE_URL` | `https://plandit.app` once the site forwards `/p/` and `/static/shares/` here; blank, `/p/` links use this API's own host |
| `REQUEST_BASE_URL` | `https://plandit.app` once the site forwards `/g/`, `/static/shares/` and `/static/plans/` here; blank, `/g/` links use this API's own host. Separate from `SHARE_BASE_URL`, so moving `/p/` links to the site can't break `/g/` links |
| `INVITE_BASE_URL` | `https://plandit.app` once the site forwards `/j/` and `/static/shares/` here; blank, group plan invite links (`/j/<token>`) use this API's own host. Separate from the other two, so each kind of link moves on its own |
| `DJANGO_CSRF_TRUSTED_ORIGINS` | `https://plandit.app` once the site forwards `/p/` or `/g/` here (`SHARE_BASE_URL`, `REQUEST_BASE_URL`): the answer forms post from that origin, and Django's CSRF check refuses origins other than this API's own host unless they're listed |

Point `api.plandit.app` at the host, then set `endpoint: "https://api.plandit.app/api/waitlist/"`
in `website/config.js` so the landing page's form starts saving signups.

## API

JSON in and out, snake_case keys, money as numbers, UUID ids, ISO 8601 timestamps. Every route
needs `Authorization: Bearer <Supabase access token>` except `/api/health/`, `/api/waitlist/`,
`/api/metrics/` (public, counts only), the public shared-plan page `/p/<slug>` and friends' input page `/g/<slug>`, with their answer form posts, and the group plan invite page `/j/<token>`. Unauthenticated calls get `401`; another user's objects return `404`.

| Method | Path | What it does |
|---|---|---|
| GET | `/api/health/` | `{"status":"ok"}` after a database ping |
| POST | `/api/waitlist/` | `{"email","source"}` → `201` stored, `200` already there. 10/min per IP |
| POST | `/v1/social-evidence` | authenticated TikTok/Instagram caption evidence; 100/day per user by default |
| GET, PATCH | `/api/me/` | profile: `name`, `school`, `home_base`, `default_budget`, `travel_modes` |
| DELETE | `/api/me/` | delete the account: the Supabase auth user (Admin API), then every Plandit row, then, once that is committed, the person's Sign in with Apple tokens. Optional body `{"apple_authorization_code": "..."}` from Apple accounts; the server exchanges it and revokes the tokens (best effort: a failure is logged, the deletion stands). `204`; `502` and nothing deleted if Supabase fails, so the app can retry. A tombstone keeps the still-valid token from re-creating the profile (`401 Account deleted.`) |
| GET | `/api/me/stats/` | `plans_completed`, `neighborhoods_visited`, `miles_walked`, `average_spend`, `plans_under_budget`, `streak_weeks` |
| GET | `/api/me/snapshot/` | the app's whole local store for this account: `{"version", "updated_at", "data"}`; `data` is the iOS `StoreSnapshot` exactly as sent (camelCase). `404` until the first PUT |
| PUT | `/api/me/snapshot/` | `{"data": {...}}` → `{"version", "updated_at"}`; last writer wins, `version` starts at 1. `data` must be an object under 1,000,000 bytes (`413`). Mirrors `data.profile` into `/api/me/` and marks the account activated when a plan has stops |
| POST | `/api/me/events/` | `{"name": "link_saved"\|"place_saved"\|"plan_built"\|"suggestion_used", "occurred_at"?}` → `201`. `occurred_at` is clamped to the last 7 days; `plan_built` activates the account. 120/min per user |
| GET | `/api/metrics/?days=30` | aggregate usage for the course staff; no JWT and, by default, no key (`METRICS_PUBLIC`). With `METRICS_PUBLIC=0`, the key goes in the `X-Metrics-Key` header (`?key=` also works but lands in access logs). `totals` (signups, real users, actives, events, waitlist, anonymous sessions, shared plans with friends' answers and answers per such plan: `links_with_answers`, `answers_per_link`) plus friends' input links, how many were built, and how many have friends' answers with answers per such link (`plan_requests`, `plan_requests_built`, `request_links_with_answers`, `answers_per_request_link`), group plans members edit together (`group_plans`, `group_plans_with_friends` with 2+ members, `group_plan_edits`, `edits_per_group_plan`), and a zero-filled `daily` series of `days` (1–365) entries in America/New_York. Counts only, never emails. `404` when `METRICS_API_KEY` is unset, `403` on a bad key, 30/min per IP |
| GET | `/api/places/?q=&category=` | search the shared place catalog (max 100) |
| GET | `/api/places/<id>/` | one place |
| GET | `/api/saved/` | my saved posts, newest first |
| POST | `/api/saved/` | `{"url","shared_text"}` → saves and extracts. `201` new, `200` if that URL was already saved |
| GET, PATCH, DELETE | `/api/saved/<id>/` | PATCH `caption`, `tags`, `estimated_cost`, `place_id` (setting a place marks it `ready`) |
| POST | `/api/saved/<id>/retry/` | run extraction again |
| GET | `/api/plans/` | my plans, newest first (summaries with `stop_count`, `total_cost`) |
| POST | `/api/plans/` | `{"date","title","budget"}` all optional; one plan per date |
| GET | `/api/plans/today/` | today's plan, created on first call |
| GET, PATCH, DELETE | `/api/plans/<id>/` | full plan with `stops`, `legs`, `total_cost`, `walking_miles` |
| POST | `/api/plans/<id>/stops/` | `{"saved_post_id"}` or `{"place_id"}` plus optional `start`, `duration_minutes`, `estimated_cost`, `note` |
| POST | `/api/plans/<id>/stops/reorder/` | `{"stop_ids":[...]}` every stop exactly once |
| PATCH, DELETE | `/api/plans/<id>/stops/<stop_id>/` | PATCH `status`, `start`, `duration_minutes`, `estimated_cost`, `note` |
| POST | `/api/plans/<id>/build/` | the planner: `{"saved_post_ids":[...], "start", "end", "budget", "mode":"add"\|"replace", "dry_run"}`; returns the plan plus `skipped` (`closed`, `over_budget`, `out_of_time`, `evening_only`). `dry_run` previews without saving. Same rules as the iOS planner; see `plandit/plans/planner.py` |
| POST | `/api/shares/` | share a plan as a link: camelCase, display-ready texts from the app (`planId`, `title`, `dateText`, `timeText`, `note`, `costText`, `stops[]`, `legs[]`; see `contracts/openapi.yaml`) → `{"slug","url"}`. `201` new, `200` when that plan already had a link (same slug, page updated). One link per plan per account. Optional `request`: the slug of your friends' input link the plan was built from; it marks that request built and its `/g/` link opens this plan (not stored with the plan; another account's or an unknown slug is `400` `{"request": ["No such request."]}` and nothing is saved). Optional, for friends' answers: `answers` (boolean), `date` (`YYYY-MM-DD`, needed with `answers: true`), `stops[].id` and `stops[].alternates` (≤ 2 of `{id, name, neighborhood, kind, costText}`), ids as UUIDs kept as sent. Updating keeps answers and drops swaps for stops no longer in the plan |
| DELETE | `/api/shares/<slug>/` | stop sharing: `204`, the page 404s at once, and friends' answers are deleted. Another account's slug is `404` |
| GET | `/api/shares/<slug>/answers/` | friends' answers on your link, oldest first: `{"answers": [{"id","name","status":"in"\|"out","swaps":{stopId: alternateId\|null},"createdAt","updatedAt"}]}` (camelCase, UTC). Another account's slug is `404` |
| DELETE | `/api/shares/<slug>/answers/<id>/` | remove a friend's answer: `204`, gone from the page at once. The id may be in either case (the app sends upper case). Otherwise `404` |
| POST | `/api/plan-requests/` | a friends' input link ("Ask friends what works"): camelCase `places` (2 to 10 of `{id, name, neighborhood, kind, costText}`, ids as UUIDs kept as sent, each once), `day` (`YYYY-MM-DD`, today to 14 days ahead in `timeZone`), `windowStart`/`windowEnd` (`HH:MM`, at least 1 hour apart on that day), `timeZone` (IANA), `answersBy` (with `Z` or an offset, after now and no later than the end of the range) → `201` with the request (below) |
| GET, DELETE | `/api/plan-requests/<slug>/` | GET: `{"slug","url","status":"open"\|"closed"\|"built","places","day","windowStart","windowEnd","timeZone","answersBy","planSlug","createdAt","answers":[{"id","name","budget","freeFrom","freeUntil","stars","createdAt","updatedAt"}]}`, answers oldest first. DELETE: `204`, the link and every answer gone. Another account's slug is `404` |
| POST | `/api/plan-requests/<slug>/close/` | stop taking answers before the deadline: `204` (also when already closed; a built request stays built). With or without the last slash |
| DELETE | `/api/plan-requests/<slug>/answers/<id>/` | remove a friend's answer: `204`. The id may be in either case. Otherwise `404` |
| POST, GET | `/api/group-plans/` | POST: a group plan from one of your plans (camelCase `date` = `YYYY-MM-DD`, from the earliest day that isn't over (below) to 366 days ahead in New York time, and `plan` = the app's `DayPlan` JSON: at most 64 KB compact, 32 levels deep and 20 stops, each stop, place, leg and cost item with the keys and the types of value the app decodes (dates as numbers, a stop's `status` and a place's `category` among the app's values; missing or null optional values and unknown keys are fine), and ids in the 36-character UUID form) → `201` with the group (below), or `200` with the existing group when you already made one from that plan id. Anonymous sessions `403`. GET: `{"groups":[{"id","date","version","membersVersion","etag","organizerName","memberCount","memberId","isOrganizer","inviteUrl"}]}`, soonest first |
| GET, PUT, DELETE | `/api/group-plans/<id>/` | GET: `{"id","date","version","membersVersion","plan","members":[{"id","name","isOrganizer"}],"memberId","isOrganizer","inviteUrl"}` (`inviteUrl` for the organizer only), `ETag: "<version>.<membersVersion>"`, `Cache-Control: private, no-cache`; a matching `If-None-Match` (weak) is `304`. PUT `{"baseVersion","editId","edit":{"kind","stopIds"},"plan"}`: `200` `{"version","membersVersion","members"}`, or `409` `{"version","membersVersion","plan","members","edits","editsFrom"}` from an old version, or `200` with the original version when you resend an `editId` you already stored (another member's is `400`); `400` once the plan's day has passed. DELETE (organizer): `204`, the group is gone. Anyone not in the group gets an empty `404` |
| POST | `/api/group-plans/<id>/invite` | the organizer replaces the invite link: `200` `{"inviteUrl"}`; the old link stops working and `membersVersion` goes up, so the ETag changes. With or without the last slash |
| DELETE | `/api/group-plans/<id>/members/<member id>/` | leave (your own member id) or, as the organizer, remove someone, who then can't rejoin with the link: `204`. The organizer leaving is `400` (end the group instead) |
| GET | `/api/group-plans/invites/<token>/` | before joining: `{"organizerName","date","memberCount"}`, nothing else. `404` when the link was replaced, the group ended or is full, the day is over, or you were removed |
| POST | `/api/group-plans/invites/<token>/join` | join: `200` with the group, as GET answers it; joining again changes nothing. Same `404`s as above; anonymous sessions `403`. With or without the last slash |
| GET | `/p/<slug>` | the public page (HTML, no sign-in, `noindex`, Open Graph tags for link previews). Link host is `SHARE_BASE_URL` when set (`https://plandit.app` once the site forwards `/p/` here), else this API's own host. Plans shared with `answers: true` also show who's in (count and up to 3 first names; never who can't make it), "I'd swap this" on stops with ids, and the answer form; those pages are `private, no-store` |
| POST | `/p/<slug>/answer` | the page's form (CSRF token, `name`, `status` = `in`\|`out`, `swap` = stop ids, `swap_to_<stopId>` = alternate id). Upserts this browser's answer by its `pa` cookie (path `/p/<slug>`; only the hash is stored; set again on every answer to last until the answers are deleted, at least 30 days) and answers `303` to the page; `400` or `429` show the page again with the reason. 20 answers per address per hour on each link, 50 per link. `404` unless shared with `answers: true` |
| POST | `/p/<slug>/answer/delete` | takes back this browser's own answer, `303` to the page. Works on any link that exists, even after it stops taking answers; `404` only for a missing link. Not rate limited |
| GET | `/g/<slug>` | friends' input page (HTML, no sign-in, `noindex`, `private, no-store`). Link host is `REQUEST_BASE_URL` when set, else this API's own host. While open and before `answersBy`: the day, range and deadline, how many answered (never anyone's answer), the places with costs and a checkbox each, and the form (no JavaScript). Once built and its plan still shared: `302` to `/p/<plan slug>`, except for a browser whose answer is still on the request, which gets a page with the plan's link and "Take back my answer". Otherwise "This plan isn't taking answers any more" |
| POST | `/g/<slug>/answer` | the page's form (CSRF token, `name`, `budget` = 0 to 150 in steps of 5, from a select rather than the architecture's slider, which can't show its value without JavaScript; `free_from`/`free_until` = `HH:MM` inside the range, `star` = up to 3 place ids). Upserts this browser's answer by its `pa` cookie (path `/g/<slug>`) and answers `303` to the page; `400` or `429` show the page again with the reason; `410` the closed page. Same limits as `/p/`: 20 per address per hour on each link, 50 per link |
| GET | `/j/<token>` | group plan invite page (HTML, no sign-in, `noindex`, `no-referrer`, `public, max-age=60`): the same static page for every token, from no database query. It gives three steps: get Plandit (with the App Store link) and sign in, copy the link, and paste it in Saved. A malformed token gets a 404 page |
| POST | `/g/<slug>/answer/delete` | takes back this browser's own answer, `303` to the page. Works on any request that exists, even once closed; `404` only for a missing link. Not rate limited |

Every plan mutation returns the full plan, with legs rebuilt between consecutive stops.

Enum values: saved `status` = `processing | ready | needs_review | failed`; `platform` =
`tiktok | instagram | web`; place `category` = `food | coffee | activity | outdoors | culture |
nightlife | shopping`; stop `status` = `done | now | upcoming`; leg `mode` = `walk | subway | bus`.
These are the iOS enums with snake_case raw values.

## Friends' answers (group plans)

Friends who open a shared plan's link can answer without an account, on plans the app shared with
`answers: true`. Only their first name is free text (`plandit/core/public_forms.py`). Answers are
deleted with the link, when the organizer removes them, and 30 days after the plan's `date`
(`plandit/core/retention.py`). The deletion runs on every answer post, page view with the form and
owner list, and by hand with `python manage.py purge_expired`.

Limits: 20 answers an hour from one address on each link (per link, so students behind one campus
address don't share a limit across every link), and 50 answers per link. A friend can always take
back their own answer while the link exists. Answers are saved with the link's row locked, and
stopping sharing or deleting the account takes that lock before deleting, so an answer saved at
the same moment is deleted with the rest.

## Friends' input links (group plans, mode 2)

The organizer picks 2 to 10 saved places, a day, a time range and a deadline, and sends the
`/g/<slug>` link. Friends answer without an account: a first name, a budget for the day (train
included), when they're free inside the range, and up to 3 starred places. The page shows each
friend only how many have answered. The organizer reads every answer through
`/api/plan-requests/<slug>/`, builds the plan on the phone, and shares it with `request=<slug>`;
the request is then `built` and its link redirects to the plan's `/p/` page. A friend whose
answer is still on it gets the plan's link and "Take back my answer" instead. The form and that
page name the organizer by the first word of their profile name, as group plan members see each
other (`first_name_of`); with no name that passes the first-name check, they name no one. The name
is only on the pages, never in the API.

The answer form has the same protections as `/p/`'s, from the same helpers: Django's CSRF token,
20 answers an hour from one address on each link, 50 per link, the first-name check and the `pa`
cookie (only its hash is stored). Answers are saved with the request's row locked; deleting the
request or the account takes that lock first (shared plans, then requests), so an answer saved at
the same moment is deleted with the rest. Requests and their answers are deleted 30 days after the
request's day (`plandit/core/retention.py`), with the request, or with the account.

Before `/g/` links go out on plandit.app, the site has to forward `/g/` (and the pages'
stylesheets under `/static/shares/` and `/static/plans/`) here, as for `/p/`; only then set
`REQUEST_BASE_URL`. It is separate from `SHARE_BASE_URL`, so `/p/` links can move first.

## Group plans members edit together (group plans, mode 3)

The organizer turns one of their plans into a group plan and sends its `/j/<token>` link. Friends
with Plandit accounts paste it into the app, preview who's planning and the day, and join; up to 8
people, the organizer included. Everyone edits the same plan, stored on the server as the app's
`DayPlan` JSON, never in anyone's `AppSnapshot`.

- Edits are compare-and-swap: a PUT names the `baseVersion` it started from and is stored only
  from the current version; otherwise `409` returns the stored plan and the logged edits since that
  version, with their authors' names as of now, so the app can apply its edit again or say who
  changed that stop. Each PUT carries an `editId`; the same member's retry of a stored edit
  answers with its version and changes nothing. The latest 200 edits per group are kept, and a
  `409`'s `editsFrom` says which version its list starts at.
- The ETag has both the plan's `version` and `membersVersion`, so a poll sees joins, removals and
  a new invite link. Polls never run the retention purge.
- Members are addressed by member id; no response carries a profile id or an email. Anyone not
  in the group gets the same empty `404` as for a group that doesn't exist.
- A plan's day ends at 4 AM New York time the morning after its date, so a night out stays
  editable while people are out. Then edits are refused and the link no longer previews or joins;
  members can still read it until it's deleted, 30 days after its date
  (`plandit/core/retention.py`), with the organizer's account, or when the organizer ends it. A
  member who deletes their account leaves every group.
- Locking: a write by someone who may not make it is `404` before any lock; every group write
  locks the group's row by its key and checks membership again under that lock; create and join
  take the caller's profile's key-share lock first; deleting an account locks its shared plans,
  requests, then group plans before the cascade, and the purge locks expired groups before
  deleting them. Each write sets a 3 s `lock_timeout` and answers `503` "Try again in a moment."
  when it runs out.

Before `/j/` links go out on plandit.app, the site has to forward `/j/` (and the page's stylesheets
under `/static/shares/`) here; only then set `INVITE_BASE_URL`.

## Decisions and what is still stubbed

- **Place matching** is `NameMatcher`: it only recognises places already in the catalog by name.
  Point `PLANDIT_PLACE_MATCHER` at a class with the same `match(text)` method to plug in an LLM
  plus a places API. Ask the team before adding a paid API.
- **Extraction runs inline** in the request (one oEmbed call plus a query). Move it to a worker
  once the matcher gets slower.
- **Instagram metadata** needs a Meta app token for oEmbed; Instagram posts are matched from the
  `shared_text` the share extension passes along.
- **Travel legs** use the iOS scaffold's heuristic (walk under 1.2 mi at 20 min/mi, otherwise
  subway at $2.90). No real routing or transit yet.
- **No planner** re-optimises order, time, or budget. Stops are appended.
- **Stats** are computed per request from past plans. Fine until plans number in the thousands.
