# Revoke Sign in with Apple tokens on account deletion (Whetstone)

Status: approved by Abraham on 2026-11-10. Branch `feature/apple-token-revocation`.

## Problem

App Store guideline 5.1.1(v) says apps that offer Sign in with Apple must use Apple's REST API to
revoke the person's tokens when they delete their account. Today `DELETE /api/me/` deletes the
Supabase user and all Plandit data but never tells Apple. Plandit stays listed under the person's
Apple ID ("Sign in with Apple" apps), and App Review can reject the 1.0 submission for it.

## Behavior

- **Apple accounts:** Settings → Delete account → the existing confirmation → the system Sign in
  with Apple sheet (Face ID or passcode, no name or email requested) → the app sends
  `DELETE /api/me/` with `{"apple_authorization_code": "<code>"}` → the account is deleted as
  today and Apple's token is revoked.
- **Person cancels the Apple sheet:** nothing is deleted, no error shown. They stay in Settings.
- **Apple sheet fails for another reason:** the account is deleted anyway, without a code (no
  revocation, a server log line). No error is shown for the sheet; the DELETE result is handled as
  usual (204 signs out, 502 shows `AuthCopy.deleteFailed`). No new user-facing copy.
- **Email accounts that later linked Sign in with Apple** (`app_metadata.providers` contains
  `"apple"`) are treated as Apple accounts: same sheet, same code.
- **Email accounts:** unchanged, no Apple sheet, no body.
- **Old app builds** send no code: deletion works as today, no revocation, a log line.

## Server

`DELETE /api/me/` accepts an optional JSON body `{"apple_authorization_code": string}`.
Order: Supabase auth user delete (unchanged, still gates everything: a failure is 502 and nothing
else happens) → Django delete and tombstone (unchanged) → only after that deletion is committed
(`transaction.on_commit`), Apple revocation, best effort → 204. The no-service-key path likewise
deletes the rows first and revokes last.

Apple revocation, best effort (a failure is logged and the deletion still completes, because the
person asked to delete and Apple also lets them remove the app under their Apple ID settings):

1. Skip with a warning if there is no code (missing, blank, over 1024 characters or not printable
   ASCII) or the Apple settings are not configured.
2. `client_secret`: an ES256 JWT, header `kid` = key id, claims `iss` = team id, `iat` = now,
   `exp` = now + 5 minutes, `aud` = `https://appleid.apple.com`, `sub` = client id. Signed with the
   Sign in with Apple private key. PyJWT[crypto] is already a dependency, so no new library.
3. `POST https://appleid.apple.com/auth/token` (form: `client_id`, `client_secret`, `code`,
   `grant_type=authorization_code`), timeout 4 s (2 s to connect), via httpx (already a dependency).
4. `POST https://appleid.apple.com/auth/revoke` with the `refresh_token` from step 3
   (`token_type_hint=refresh_token`), or the `access_token` if no refresh token came back.
5. Never log the code, tokens, client secret or private key. Log only the outcome and the HTTP
   status. Any other exception (bad key, JWT or encoding error, a bug) is caught and logged by
   its type name only, never its message or a traceback.

Settings (environment, `render.yaml` with `sync: false`, empty in `settings_test.py`):
`APPLE_TEAM_ID` (9A6H44778K), `APPLE_CLIENT_ID` (default `com.plandit.app`),
`APPLE_SIGNIN_KEY_ID`, `APPLE_SIGNIN_PRIVATE_KEY` (the `.p8` contents; `\n` escapes accepted).
New module `backend/plandit/core/apple_signin.py`, next to `supabase_admin.py` and in its style.

## iOS

- `AppleReauthorizing` protocol with one async method that returns the authorization code string,
  throws a cancel error or a failure. Live version: `ASAuthorizationController` with an
  `ASAuthorizationAppleIDProvider` request, no scopes. Injected into `AccountModel` so tests use a
  fake.
- `AuthUser.signedInWithApple`: `app_metadata.provider == "apple"` or `app_metadata.providers`
  contains `"apple"`. Sessions stored by earlier builds (no `providers`) decode as before.
- `AccountModel.deleteAccount()`: when `currentUser.signedInWithApple`, get the code first; cancel
  → return quietly, no request; any other failure → delete without a code. Then `PlanditAPIClient.deleteAccount(appleAuthorizationCode:)`
  sends the JSON body (no body when nil).
- `-skipAuth` UI test account is `email`, so UI tests are unaffected.

## Out of scope

Revoking at sign-out (not required), storing Apple refresh tokens (never stored), Supabase's own
identity unlinking (the Supabase user is deleted anyway).

## Questions (defaults taken)

1. Apple revocation failure: **best effort, deletion completes** (alternative: 502 and keep the
   account, like a Supabase failure). Say if you want the strict version.
2. Re-confirming with Apple at delete time instead of storing a refresh token at sign-in: avoids
   keeping Apple tokens in the database, at the cost of one Face ID prompt during deletion.

## Verification

| Requirement | Proof |
|---|---|
| Code exchanged and revoked, in order, with a correct client secret | pytest with httpx mocked: token then revoke calls, form fields, JWT header and claims verified with a test EC key |
| Refresh token missing → access token revoked | pytest |
| No code / settings missing / Apple 4xx-5xx / timeout → still 204, data deleted, warning logged without secrets | pytest, with `caplog` asserting no code or token text |
| Supabase failure still 502 and nothing deleted, Apple not called | pytest |
| Body optional; old clients unchanged | existing delete tests pass untouched |
| Apple account: code requested and sent; cancel → no request; failure → DELETE without a code, signs out on 204 | iOS unit tests with a fake reauthorizer and transport |
| Apple step crashes (bad key, any exception), hangs or the worker dies → rows already deleted and tombstone written | pytest: bad keys and arbitrary exceptions through the view; a transactional test where the Apple fake checks the deletion is committed; a `BaseException` from either Apple call |
| Linked Apple identity counts as Apple; legacy Keychain sessions decode | iOS unit tests |
| Email account: no Apple prompt, no body | iOS unit test |
| Real revocation | Manual, after the key is set on Render: delete an Apple test account on a device, then check Settings → Apple ID → Sign in with Apple no longer lists Plandit |
| Lint and suites | `ruff check . && ruff format --check .`, full pytest on local Postgres, iOS unit + UI tests on iPhone 17 Pro and an iOS 18 simulator |

## Rollout

1. Abraham creates the key: Apple Developer → Certificates, Identifiers & Profiles → Keys → `+` →
   name "Plandit Sign in with Apple", tick Sign in with Apple → Configure → primary App ID
   `com.plandit.app` → Continue → Register → Download the `.p8` (only downloadable once). Note
   the Key ID.
2. Render → plandit-api → Environment: set `APPLE_SIGNIN_KEY_ID`, `APPLE_SIGNIN_PRIVATE_KEY`
   (paste the file contents), `APPLE_TEAM_ID` = `9A6H44778K`. Never commit the `.p8`.
3. Merge (backend auto-deploys; safe before the key exists, it just skips). The iOS change ships
   in the 1.0 build.

## Build notes (decided during the build, 2026-11-10)

- **Body handling.** `apple_authorization_code` that is missing, not a string, blank or longer than
  1024 characters counts as no code (a warning, then deletion as today), never a 400. The same
  for a body that is not JSON or not a JSON object: the person asked to delete, and revocation is
  best effort. `backend/plandit/core/apple_signin.py: usable_code`, `views.py: MeView._body_field`.
- **No service key.** When `SUPABASE_SERVICE_ROLE_KEY` is empty the view still attempts the Apple
  revocation (after its existing warning, after the rows are deleted and committed); the rest of
  that path is unchanged (no tombstone).
- **Log lines.** "No Apple authorization code for <id>" is a warning for every delete without a
  body, including email accounts (the server does not look at the provider). Success is one
  `INFO` line naming the token type (`refresh_token` or `access_token`); failures are one warning
  with the step and the HTTP status or the httpx error class. Nothing else is logged.
- **Settings.** `backend/.env.example` lists the three new variables. The literal `\n` to newline
  conversion happens in `settings.py` (tested by loading `settings.py` afresh).
- **iOS.** `AppleReauthorizer` is the default `appleReauthorizer` argument of `AccountModel.init`;
  it refuses a second sheet while one is up (throws `failed`). `isBusy` stays true while the Apple
  sheet is showing. `PlanditAPIClient.deleteAccount(appleAuthorizationCode:)` defaults to `nil`
  so the existing call sites and tests compile unchanged. New tests in
  `ios/PlanditTests/AppleReauthorizationTests.swift`.
- **Revision after review (2026-11-10).**
  - *Order: Supabase → Django delete committed → Apple last* (`views.py: MeView.delete`,
    `_revoke_apple_tokens_after_commit`). Reason: an Apple-side crash after the Supabase delete left
    the person's data behind with no way to retry (the app no longer had a session). The revocation
    runs in `transaction.on_commit` registered inside the deletion's transaction: production has no
    `ATOMIC_REQUESTS`, so it runs right after the commit, and under any outer transaction it waits
    for that commit. A crash, hang or killed worker during the Apple calls now costs only the
    revocation.
  - *Every exception is caught* (`_revoke_apple_tokens`). Reason: the same crash (a bad `.p8`,
    an RSA or public key, a JWT or encoding error) must never fail a deletion. Unexpected ones are
    logged as `unexpected <TypeName>` only, because their messages can echo the key or the code.
  - *Timeouts 4 s, 2 s to connect* (`apple_signin.TIMEOUT`). Reason: Apple now runs inside the
    request after the commit, so a slow Apple must not hold up the 204 for long.
  - *Codes must be printable ASCII* (`usable_code`). Reason: Apple's codes are ASCII; a lone
    surrogate in valid JSON crashed httpx's form encoding.
  - *Apple sheet failure deletes without a code* (`AccountModel.deleteAccount`). Reason: in-app
    deletion must always work; revocation is best effort. Cancel still deletes nothing.
  - *Linked identities* (`AuthUser.providers`). Reason: an email account that later used Sign in
    with Apple has `provider == "email"` but Apple tokens to revoke; `providers` is optional so
    sessions already in the Keychain still decode.
  - *Delete is ignored while one is already running* (`AccountModel.deleteAccount`). Reason: a
    second tap while the Apple sheet is up made the sheet fail, which deleted the account without
    a code even if the person then canceled the sheet they could see.
  - *The Apple check also reads the refreshed session* (`AccountModel.usesSignInWithApple`).
    Reason: a session stored by an older build has no `providers`; once a refresh records them,
    an email account with Apple linked still gets the sheet.
- **Test environment.** This machine has only the iOS 27.2 simulator runtime and had no
  "iPhone 17 Pro" device, so one was created (`xcrun simctl create`). The iOS 18 run in the
  verification table could not be done here: no iOS 18 runtime is installed.

## Review

Independent reviewer (auth change): reviewer at xhigh, checking the integrated diff against this
spec with pass / fail / unverified per row. Human gates: spec approval, merge, Render settings.
