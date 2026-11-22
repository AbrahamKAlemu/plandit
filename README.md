# Plandit

Plandit is a day planner for college students: answer 3 to 5 quick questions (budget, how far
you'll go, solo or with friends, what you're into) and get a ready-to-go plan for your day,
nearby and on budget, shown on a map.

## Usage metrics API (for course staff)

Sign-ups and usage are live at:

```
GET https://plandit-api.onrender.com/api/metrics/?days=30
```

- **No key needed.** It's a plain GET with no sign-in, header or key, so any tool or agent can read
  it. (If the team ever turns the key back on, the API answers `403` and the team will send it.)
- **`days`:** 1 to 365, default 30. Anything else answers `400`.
- **Limit:** 30 requests a minute per IP address, then `429`.
- **Privacy:** counts only, never names, emails or ids.
- The first call can take up to a minute if the server was asleep. Try again before deciding it's
  down.

```sh
curl -s "https://plandit-api.onrender.com/api/metrics/?days=30"
```

### What it returns

- `product`, `generated_at` (UTC), `timezone` (`America/New_York`, which sets where each day
  starts), and `definitions` (the three below, in words).
- `totals`, counted over all time unless the name says otherwise:
  - `signups`, `real_users`, `activation_rate` (real users ÷ signups);
  - `active_users_today`, `active_users_7d`, `active_users_30d`;
  - `plans_built`, `places_saved`, `links_saved`;
  - `waitlist_signups` (emails left on the website's waitlist);
  - `anonymous_sessions` (installs from early TestFlight builds, before accounts existed).
- `daily`: one entry per day for the last `days` days, oldest first, with zeros on days with no
  activity. Each has `date`, `signups`, `new_real_users`, `active_users`, `plans_built`,
  `places_saved` and `links_saved`.

### Definitions

- **Signup:** an account created with email or Apple that has opened the app at least once.
- **Real user:** a signup who built a plan with at least one stop, Plandit's core action.
- **Active user:** a signup who used the app that day.

Anonymous sessions count only in `anonymous_sessions`, never in the other numbers.

The code is in `backend/plandit/core/metrics.py` (what's counted) and `MetricsView` in
`backend/plandit/core/views.py`. The tests are in `backend/tests/test_metrics.py`.

## What's in this repo

- `ios/`: the iPhone app (SwiftUI). Setup in [ios/README.md](ios/README.md).
- `backend/`: the API (Django REST Framework on Supabase Postgres, hosted on Render). Every route
  is listed in [backend/README.md](backend/README.md#api).
- `website/`: the landing page's source. The live plandit.app is deployed from a fork; see
  [AGENTS.md](AGENTS.md).
- `docs/features/`: each feature's design and build record.
- [AGENTS.md](AGENTS.md): how the team works, for people and coding agents.
