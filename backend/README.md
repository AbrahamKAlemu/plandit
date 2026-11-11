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
    plans/           Day plans, stops, travel legs
    waitlist/        Public signup endpoint used by website/
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
`/api/me/snapshot/` and report `link_saved`, `place_saved` and `plan_built` through
`/api/me/events/`. A **real user** is a non-anonymous profile with `activated_at` set, which
happens on the first `plan_built` event or the first snapshot containing a plan with stops.

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
| `METRICS_API_KEY` | shared secret for `GET /api/metrics/` (course staff). Empty turns the endpoint off. The Render blueprint generates one |

Point `api.plandit.app` at the host, then set `endpoint: "https://api.plandit.app/api/waitlist/"`
in `website/config.js` so the landing page's form starts saving signups.

## API

JSON in and out, snake_case keys, money as numbers, UUID ids, ISO 8601 timestamps. Every route
needs `Authorization: Bearer <Supabase access token>` except `/api/health/`, `/api/waitlist/` and
`/api/metrics/` (secret key). Unauthenticated calls get `401`; another user's objects return `404`.

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
| POST | `/api/me/events/` | `{"name": "link_saved"\|"place_saved"\|"plan_built", "occurred_at"?}` → `201`. `occurred_at` is clamped to the last 7 days; `plan_built` activates the account. 120/min per user |
| GET | `/api/metrics/?days=30` | aggregate usage for the course staff; no JWT, key in the `X-Metrics-Key` header (preferred; `?key=` also works but lands in access logs, so rotate the key after the course). `totals` (signups, real users, actives, events, waitlist, anonymous sessions) plus a zero-filled `daily` series of `days` (1–365) entries in America/New_York. Counts only, never emails. `404` when `METRICS_API_KEY` is unset, `403` on a bad key, 30/min per IP |
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

Every plan mutation returns the full plan, with legs rebuilt between consecutive stops.

Enum values: saved `status` = `processing | ready | needs_review | failed`; `platform` =
`tiktok | instagram | web`; place `category` = `food | coffee | activity | outdoors | culture |
nightlife | shopping`; stop `status` = `done | now | upcoming`; leg `mode` = `walk | subway | bus`.
These are the iOS enums with snake_case raw values.

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
