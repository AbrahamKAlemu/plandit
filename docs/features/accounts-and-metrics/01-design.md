# Accounts, cloud sync and usage metrics

Status: approved by Abraham on 2026-11-07 (decisions below). Branch `feature/accounts-sync-metrics`.

## Why

Class 8 (Oct 30) moved every team into beta: the leaderboard counts **real users**, defined as
"signed up and did the core action once", and it is 10% of the grade. Plandit today has no sign-up:
the iOS app keeps everything in a JSON file on the phone and only holds an anonymous Supabase
session for link extraction. We cannot count sign-ups, real users or actives, and a reinstall loses
everything. The professor also wants an API to pull our sign-ups and usage.

## Decisions (Abraham, 2026-11-07)

| Question | Decision |
|---|---|
| How app data reaches the database | **Per-account cloud copy.** The app's whole `StoreSnapshot` (saved places, today, past plans, visited, profile) is stored per account in Postgres and synced on change and on sign-in. The relational `saved/` and `plans/` tables stay as they are, unused by iOS for now. |
| Core action for "real user" | **Built a plan**: a plan with at least one stop. |
| Sign-in methods | **Email + password, and Sign in with Apple.** No new libraries (URLSession, AuthenticationServices, CryptoKit). |
| Metrics API access | **Secret key**, aggregate counts only, never emails. |

Defaults taken without asking (say so in the PR):
- An account is required to use the app. No guest mode.
- New accounts start empty (no sample data). A device's pre-account data is migrated into the
  first account that signs in on it: only the saved posts the person actually saved (sample posts
  dropped), not the sample plan.
- Sync is last-writer-wins per account, with a version number so a device pulls newer data on
  foreground when it has no unsynced changes of its own.
- No "forgot password" in this slice (Supabase's reset link needs a web page to set the new
  password). Follow-up.
- Account deletion is in-app (App Store guideline 5.1.1(v)).

## What a "real user" is, exactly

- **Sign-up**: a `Profile` that is not anonymous (email or Apple), counted from `signed_up_at`
  (first time the API saw a non-anonymous token for that user).
- **Real user**: a sign-up with `activated_at` set. `activated_at` is set the first time either
  (a) the app posts a `plan_built` event, or (b) a snapshot PUT contains a plan with stops
  (`today.stops` non-empty, or a `pastPlans` entry with `stopCount > 0`). New accounts start with neither, and the
  migration from pre-account data drops plans, so (b) only fires on a plan the person built.
- **Active user on a day**: a sign-up who made any authenticated API call that day
  (America/New_York). Recorded at most once per 5 minutes per user.
- Anonymous profiles (old TestFlight builds) are never counted except in `anonymous_sessions`.

## API contracts (backend owns, iOS consumes)

All under the existing Supabase JWT auth unless stated. JSON, snake_case envelope keys.

### `GET /api/me/snapshot/`
- `200 {"version": 3, "updated_at": "2026-11-07T15:04:05Z", "data": {...}}`
- `404 {"detail": "No snapshot yet."}`

`data` is the iOS `StoreSnapshot` exactly as the app encodes it (camelCase keys, ISO 8601 dates).
The server stores it opaquely and returns it unchanged.

### `PUT /api/me/snapshot/`
- Body `{"data": {...}}`. `data` must be a JSON object; serialized size over 1,000,000 bytes → `413`.
  Anything else invalid → `400`.
- `200 {"version": 4, "updated_at": "..."}`. Version starts at 1 on the first PUT and increments.
- Side effects, best effort (bad or missing fields are ignored, never a 400):
  - Mirror `data.profile.{name, school, homeBase, defaultBudget, travelModes}` into the `Profile`
    row (`name`, `school`, `home_base`, `default_budget` 0–10000, `travel_modes`), truncated to the
    column lengths.
  - Counters on the snapshot row: `saved_count = len(data.saved)`,
    `past_plans_count = len(data.pastPlans)`, `today_stop_count = len(data.today.stops)`.
  - If `today_stop_count > 0` or any `pastPlans` entry has an integer `stopCount > 0`, and
    `activated_at` is null → set it now.

### `POST /api/me/events/`
- Body `{"name": "link_saved" | "place_saved" | "plan_built", "occurred_at": "<ISO 8601, optional>"}`.
  `occurred_at` is clamped to `[now - 7 days, now]`; missing → now. Unknown name → `400`.
- `201 {"name": "...", "occurred_at": "..."}`.
- `plan_built` sets `activated_at` if null. Throttle scope `events`: 120/min per user.

### `DELETE /api/me/`
- Deletes the caller's Supabase auth user (Admin API, needs `SUPABASE_SERVICE_ROLE_KEY`) and then
  the `Profile` (cascades to snapshot, events, activity days, saved posts, plans), and records a
  `DeletedAccount` tombstone so a still-valid access token cannot re-create the profile (401).
- `204` on success. If the Supabase call fails (non-2xx other than 404, or network) → `502` and
  nothing is deleted, so the app can retry. If the service key is not configured → delete the
  Django data, log a warning, `204`.

### `GET /api/metrics/?days=30` (professor)
- No JWT. Key in header `X-Metrics-Key: <key>` or query `?key=<key>`, compared with
  `hmac.compare_digest` to `METRICS_API_KEY`. Setting empty → `404` (feature off). Missing or
  wrong key → `403`. Throttle scope `metrics`: 30/min per IP. `days` integer 1–365, default 30,
  otherwise `400`.
- `200`:

```json
{
  "product": "Plandit",
  "generated_at": "2026-11-07T15:04:05Z",
  "timezone": "America/New_York",
  "definitions": {
    "signup": "An account created with email or Apple that has opened the app at least once.",
    "real_user": "A signup who built a plan with at least one stop (Plandit's core action).",
    "active_user": "A signup who used the app that day."
  },
  "totals": {
    "signups": 41,
    "real_users": 23,
    "activation_rate": 0.561,
    "active_users_today": 6,
    "active_users_7d": 19,
    "active_users_30d": 35,
    "plans_built": 57,
    "places_saved": 88,
    "links_saved": 120,
    "waitlist_signups": 64,
    "anonymous_sessions": 9
  },
  "daily": [
    {"date": "2026-10-09", "signups": 2, "new_real_users": 1, "active_users": 3, "plans_built": 1, "places_saved": 4, "links_saved": 5}
  ]
}
```

`daily` runs oldest to newest, exactly `days` entries ending today, zero-filled. Event counts in
`totals` and `daily` exclude anonymous profiles. `active_users_7d` / `_30d` count distinct users
over the trailing 7 / 30 local days including today.

## Backend changes (`backend/`)

- `core.Profile` gains `is_anonymous` (bool), `auth_provider` (str, from
  `app_metadata.provider`), `signed_up_at`, `last_seen_at`, `activated_at` (nullable datetimes).
  Data migration for existing rows: `email == ""` → anonymous, else `signed_up_at = created_at`.
- New models in `core`: `AppSnapshot` (one-to-one with Profile, `data` JSONField, `version`,
  counters, timestamps), `ActivityDay` (profile, date; unique together), `ActivityEvent`
  (profile, name, occurred_at; indexed by name and time).
- RLS enabled on the three new tables, same pattern as `core.0002`.
- `SupabaseJWTAuthentication` updates claim-derived fields and records activity (throttled).
- Settings: `METRICS_API_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, throttle scopes `events`, `metrics`
  (also in `settings_test.py`). `render.yaml`: `METRICS_API_KEY` generated, service key `sync: false`.
- Admin registrations, README API table and `contracts/openapi.yaml` updated, pytest coverage.

## iOS changes (`ios/`)

- `SupabaseAuthClient` (actor) replaces `SupabaseAnonymousSession`: email sign-up, sign-in, Apple
  `id_token` sign-in with nonce, refresh (single in-flight refresh), sign-out, resend
  confirmation. Session in the Keychain; the old anonymous item is removed.
- `AccountModel` (observable) drives an auth gate: loading → welcome / email form / check-your-email
  → the existing app.
- Per-account local file `plandit-store-<user-id>.json`; `SyncCoordinator` pulls on sign-in and
  foreground, pushes debounced on change, final push before sign-out.
- Usage events from the store: `link_saved`, `place_saved`, `plan_built`.
- Settings gains an Account section: email, Sign out, Delete account.
- Profile stats computed from real past plans instead of `SampleData.stats`.
- `project.yml` adds the Sign in with Apple entitlement. `-skipAuth` launch argument keeps UI tests
  running offline.

## Setup only a human can do

1. Supabase → Authentication → Providers → Apple: enable, Client IDs `com.plandit.app`.
   **Done 2026-11-07** via the Management API.
2. Supabase → Authentication → URL Configuration: set Site URL to the live website so the
   confirmation email's link lands on a real page (or turn off "Confirm email" to cut friction).
   **Done 2026-11-07:** Site URL `https://plandit.app`, and "Confirm email" turned **off**. The
   project has no custom SMTP, and Supabase's built-in sender only delivers to project team members
   (2 emails/hour), so real students could never have confirmed. Email sign-up now returns a session
   immediately (the app handles both shapes). Turn confirmation back on only after adding SMTP.
3. Render → plandit-api → Environment: `METRICS_API_KEY` (generated by the blueprint, or set by
   hand) and `SUPABASE_SERVICE_ROLE_KEY` (Supabase → Project Settings → API keys, secret).
   **Done 2026-11-07.** Use the legacy `service_role` key (a JWT starting `eyJ`); the backend was
   tested with it, not with the newer `sb_secret_…` keys.
4. Apple Developer: the App ID `com.plandit.app` needs the Sign in with Apple capability
   (automatic signing adds it on the next archive). **Done 2026-11-07** with TestFlight build
   202611071502. `scripts/testflight.sh` fails with "No Accounts" if Xcode's Apple account session
   has expired; sign in again under Xcode → Settings → Accounts.

## Verification

| Requirement | Proof |
|---|---|
| Sign-up, sign-in, Apple sign-in, refresh, sign-out | iOS builds; manual run in Simulator against the Render API; unit tests for session decoding and nonce |
| Data stored per account in Postgres | pytest for snapshot GET/PUT, size limit, profile mirroring, isolation between users |
| Real-user counting | pytest: activation via event and via snapshot; anonymous excluded |
| Metrics API | pytest: key required, disabled when unset, wrong key, `days` bounds, zero-filled daily series, no emails in output |
| Account deletion | pytest with Supabase admin call mocked: success, failure → 502 keeps data, no key → local delete |
| Existing behavior unchanged | full pytest suite, ruff; existing iOS unit and UI tests with `-skipAuth` |
