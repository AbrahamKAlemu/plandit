# Plandit

Plandit is a day planner for college students: answer 3 to 5 quick questions (budget, how far
you'll go, solo or with friends, what you're into) and get a ready-to-go plan for your day,
nearby and on budget, shown on a map.

<!-- ASSUMPTION: this one-liner uses the language in the Oct 7 brand-position draft.
     Re-check it against docs/brand_position.md when the final version lands. -->

## Read these first
- docs/brand_position.md: how we talk and who we serve. **PENDING** (owners: Catherine Escobar,
  Eldad Workeneh Tolla, Jaden Hinton). Until it lands, follow "Product guardrails" below.
- docs/style_guide.md: how it looks. **PENDING** (owners: Catherine Escobar, Jaden Hinton).
  Until it lands, don't invent a visual style. Ask.
- .claude/agents/persona-*.md: five persona agents (synthetic users) that judge copy, pages and
  feature ideas. Run them by name, e.g. "run persona-sofia on docs/brand_position.md".
- docs/features/<feature>/: the Feature Forge record for each feature (brief, architecture, plan,
  verification, lessons).

## How to run it
- Stack: SwiftUI iOS app (`ios/`), Django + Django REST Framework API on Supabase Postgres with
  Supabase Auth (`backend/`), static landing site on Vercel (`website/`).
- Install: `cd backend && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements-dev.txt`.
  iOS: see `ios/README.md`.
- Run locally: `cd backend && docker compose up -d && python manage.py migrate && python manage.py runserver 8001`.
  Website: `cd website && python3 -m http.server 8000`. Details in `backend/README.md`.
- Test: `cd backend && pytest` (needs the compose Postgres). Lint: `ruff check . && ruff format --check .`
- Feature Forge skills are installed in `.claude/skills/` (feature-forge, brief, architecture,
  plan, whetstone). To update them, clone https://github.com/kenxle/feature-forge, move the old
  copies out, and run `python3 scripts/install.py /absolute/path/to/this/repo` from the clone.

## How we work
- Framework: Feature Forge. Use `/feature-forge` for any new feature (clarify, brief, plan,
  build, verify, ship, learn) and `/whetstone` for small, well-understood changes.
- Product guardrails:
  - We are a planner, not a discovery feed. Students already know where they want to go; the
    problem is turning that into a plan they actually go do.
  - Onboarding is a 3 to 5 question questionnaire, max: budget, distance, solo or group,
    interests.
  - Budget and distance are core inputs, not optional filters.
- User-facing copy: read docs/brand_position.md first. If copy conflicts with it, the copy is
  wrong. Until it lands, don't use "discover", "explore", "itinerary", "cheap", "hidden gems",
  "curated", "seamless", "elevate", or "AI-powered" as a headline (from the Oct 7 draft; not
  final).
- Before shipping user-facing copy or a feature brief, run the persona agents on it. A persona's
  `must_fix` blocks the change; `nice_to_have` does not.
- Small commits, one slice per PR. Ask before adding a new library, service, or paid API.
- Never commit secrets. Keys go in `.env`, which is gitignored.
- Don't edit docs/brand_position.md or docs/style_guide.md without their owners' sign-off.
- When a feature ships, the Feature Forge cleanup step updates this file with what we learned.

## Team
| Person | Owns |
|--------|------|
| Abraham Kebede Alemu | Repo setup, persona agents |
| Catherine Escobar | Brand position, style guide and logo |
| Eldad Workeneh Tolla | Brand position, Reddit research |
| Jaden Hinton | Brand position, style guide and logo, team contract |
| Hunter Doradea | TBD |
