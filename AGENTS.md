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
- Stack: native iOS app (SwiftUI, iOS 17+) in `ios/`, Django + Django REST Framework API on
  Supabase Postgres with Supabase Auth in `backend/`, static landing site in `website/`. The live
  site is deployed from a different repo; see "App Store 1.0" under What we learned.
- iOS install: Xcode 26 or later, plus XcodeGen (`brew install xcodegen`). Run locally:
  `cd ios && xcodegen generate && open Plandit.xcodeproj`, set your signing team for both
  targets, then run the Plandit scheme. Rerun `xcodegen generate` after adding or removing
  files; `ios/project.yml` is the source of truth for the Xcode project. Details in ios/README.md.
- Backend install: `cd backend && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements-dev.txt`.
  Run locally: `docker compose up -d && python manage.py migrate && python manage.py runserver 8001`.
  Details in `backend/README.md`.
- Website: `cd website && python3 -m http.server 8000`.
- Test: `cd backend && pytest` (needs the compose Postgres). Lint: `ruff check . && ruff format --check .`
  iOS: `cd ios && xcodebuild test -project Plandit.xcodeproj -scheme Plandit -destination
  'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO` (unit + UI tests).
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

## What we learned
- Accounts and metrics (Nov 2026, docs/features/accounts-and-metrics/):
  - `backend/.env` points at the production Supabase database. `pytest` refuses Supabase hosts;
    `manage.py migrate` does not, so pass a local `DATABASE_URL` when you migrate locally.
  - The app requires an account. UI tests launch with `-skipAuth` (DEBUG only) to use a local test
    account with sync off; `-resetAuth` clears the Keychain session.
  - Supabase "Confirm email" is off: there is no custom SMTP, and the built-in sender only delivers
    to team members. Add SMTP before turning it back on.
  - Class metrics: `GET https://plandit-api.onrender.com/api/metrics/?days=30` with header
    `X-Metrics-Key` (value in the Render service's environment). "Real user" = built a plan with
    at least one stop.
  - Foundation's URL behavior changes between iOS versions: `appending(path:)` doubles a trailing
    slash on iOS 18, and the API answers 404. The iPhone 17 Pro test command only covers iOS 26, so
    run the tests on an iOS 18 simulator too before a TestFlight upload. There, about 23 unit tests
    crash when a `@MainActor` object is freed ("pointer being freed was not allocated"): a bug in
    iOS 18's Swift runtime when non-async code runs inside a task-local scope, which XCTest sets up.
    Check that only those crashes fail, not assertions.
- App Store 1.0 (Nov 2026, docs/app-store/1.0-listing.md,
  docs/features/accounts-and-metrics/03-apple-token-revocation.md):
  - plandit.app is served by Vercel from Jaden Hinton's fork, Just-Jaden/plandit_website. That
    repo adds a blog build step (Sanity). This repo's `website/` is not what's live. A website
    change also needs a PR on that repo, which Jaden merges. Jaden's Vercel account is on the
    Hobby plan, which has no team members.
  - The App Store Privacy Policy and Support URLs are plandit.app/privacy and /support. Keep
    both pages live, and keep the policy in step with what the app and the site collect.
  - Deleting an account revokes its Sign in with Apple tokens only when Render has
    `APPLE_SIGNIN_KEY_ID` and `APPLE_SIGNIN_PRIVATE_KEY`. Without them, deletion still works and
    logs a warning.
  - GitGuardian scans every PR and flags realistic-looking fake tokens in tests. Use obviously
    fake values such as `fake-apple-code-for-tests`.
  - Xcode 27 can't download iOS 18 simulator runtimes. For the iOS 18 run above, use a device or
    an older Xcode.
  - `ios/scripts/testflight.sh` uploads with the Apple Account signed in to Xcode. If the upload
    fails with "Failed to Use Accounts", sign in again in Xcode → Settings → Accounts. Then rerun
    only the `xcodebuild -exportArchive` step on the archive the script already made.

## Team
| Person | Owns |
|--------|------|
| Abraham Kebede Alemu | Repo setup, persona agents |
| Catherine Escobar | Brand position, style guide and logo |
| Eldad Workeneh Tolla | Brand position, Reddit research |
| Jaden Hinton | Brand position, style guide and logo, team contract |
| Hunter Doradea | TBD |
