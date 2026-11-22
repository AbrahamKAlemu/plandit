# Plandit

Plandit is a day planner for college students: answer 3 to 5 quick questions (budget, how far
you'll go, solo or with friends, what you're into) and get a ready-to-go plan for your day,
nearby and on budget, shown on a map.

## Usage metrics API (for course staff)

Sign-ups and usage are live at:

```
GET https://plandit-api.onrender.com/api/metrics/?days=30
```

- **Key:** send it in the `X-Metrics-Key` header. If your tool can't set headers, add
  `&key=<key>` to the URL instead (that works too, but the key then shows up in server logs).
  The key isn't in this repo. Ask the Plandit team for it. Without it, the API answers `403`.
- **`days`:** 1 to 365, default 30. Anything else answers `400`.
- **Limit:** 30 requests a minute per IP address, then `429`.
- **Privacy:** counts only, never names, emails or ids.
- The first call can take up to a minute if the server was asleep. Try again before deciding it's
  down.

```sh
curl -s -H "X-Metrics-Key: $PLANDIT_METRICS_KEY" \
  "https://plandit-api.onrender.com/api/metrics/?days=30"
```

### What it returns

- `product`, `generated_at` (UTC), `timezone` (`America/New_York`, which sets where each day
  starts), and `definitions` (the three below, in words).
- `totals`, counted over all time unless the name says otherwise:
  - `signups`, `real_users`, `activation_rate` (real users ÷ signups);
  - `active_users_today`, `active_users_7d`, `active_users_30d`;
  - `plans_built`, `places_saved`, `links_saved`;
  - `waitlist_signups` (emails left on the website's waitlist);
  - `anonymous_sessions` (installs from early TestFlight builds, before accounts existed);
  - `links_with_answers` and `answers_per_link`: shared plans (`/p/` links) with at least one
    friend's "I'm in" or "Can't make it", and the average number of answers on such a plan;
  - `plan_requests` and `plan_requests_built`: friends' input links (`/g/` links) sent, and how
    many were built into a plan;
  - `request_links_with_answers` and `answers_per_request_link`: friends' input links with at
    least one friend's answer (their budget and when they're free), and the average number of
    answers on such a link. These are counted apart from the shared plans' answers above.

  Friends' answers and input links are deleted 30 days after the plan's day, so those numbers
  count what's kept now, not all time.
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
