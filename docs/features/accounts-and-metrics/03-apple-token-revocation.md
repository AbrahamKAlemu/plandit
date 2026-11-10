# Revoke Sign in with Apple tokens on account deletion (Whetstone)

Status: spec, awaiting Abraham's approval. Branch `feature/apple-token-revocation`.

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
- **Apple sheet fails for another reason:** nothing is deleted; the existing `AuthCopy.deleteFailed`
  message shows. No new user-facing copy.
- **Email accounts:** unchanged, no Apple sheet, no body.
- **Old app builds** send no code: deletion works as today, no revocation, a log line.

## Server

`DELETE /api/me/` accepts an optional JSON body `{"apple_authorization_code": string}`.
Order: Supabase auth user delete (unchanged, still gates everything) → Apple revocation → Django
delete and tombstone (unchanged).

Apple revocation, best effort (a failure is logged and the deletion still completes, because the
person asked to delete and Apple also lets them remove the app under their Apple ID settings):

1. Skip with a warning if there is no code or the Apple settings are not configured.
2. `client_secret`: an ES256 JWT, header `kid` = key id, claims `iss` = team id, `iat` = now,
   `exp` = now + 5 minutes, `aud` = `https://appleid.apple.com`, `sub` = client id. Signed with the
   Sign in with Apple private key. PyJWT[crypto] is already a dependency, so no new library.
3. `POST https://appleid.apple.com/auth/token` (form: `client_id`, `client_secret`, `code`,
   `grant_type=authorization_code`), 10-second timeout, via httpx (already a dependency).
4. `POST https://appleid.apple.com/auth/revoke` with the `refresh_token` from step 3
   (`token_type_hint=refresh_token`), or the `access_token` if no refresh token came back.
5. Never log the code, tokens, client secret or private key. Log only the outcome and the HTTP
   status.

Settings (environment, `render.yaml` with `sync: false`, empty in `settings_test.py`):
`APPLE_TEAM_ID` (9A6H44778K), `APPLE_CLIENT_ID` (default `com.plandit.app`),
`APPLE_SIGNIN_KEY_ID`, `APPLE_SIGNIN_PRIVATE_KEY` (the `.p8` contents; `\n` escapes accepted).
New module `backend/plandit/core/apple_signin.py`, next to `supabase_admin.py` and in its style.

## iOS

- `AppleReauthorizing` protocol with one async method that returns the authorization code string,
  throws a cancel error or a failure. Live version: `ASAuthorizationController` with an
  `ASAuthorizationAppleIDProvider` request, no scopes. Injected into `AccountModel` so tests use a
  fake.
- `AccountModel.deleteAccount()`: when `currentUser.signedInWithApple`, get the code first; cancel
  → return quietly; failure → `deleteFailed`. Then `PlanditAPIClient.deleteAccount(appleAuthorizationCode:)`
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
| Apple account: code requested and sent; cancel → no request; failure → `deleteFailed`, no request | iOS unit tests with a fake reauthorizer and transport |
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

## Review

Independent reviewer (auth change): reviewer at xhigh, checking the integrated diff against this
spec with pass / fail / unverified per row. Human gates: spec approval, merge, Render settings.
