# Auth and account copy (iOS)

User-facing copy for the sign-up / sign-in gate and the account section. Context: Plandit now
requires an account (email + password, or Sign in with Apple) so saved places and plans sync to
the cloud and survive a reinstall. This is the first thing a new person sees after installing the
app from TestFlight. Email sign-up requires confirming the address through an emailed link.

## Welcome screen (first launch, signed out)
- Headline: "Turn the places you want to go into a real day."
- Subhead: "Send Plandit a TikTok or Reel of a spot. You get a plan that fits your budget and your time."
- Buttons: [Sign in with Apple] (Apple's system button, first and largest), "Continue with email"
- Footnote under the buttons: "Free. No card needed. Your account keeps your places and plans if you
  switch phones."

## Email form
- Toggle: "Sign up" / "Sign in"
- Title: "Create your account" (sign up) / "Welcome back" (sign in)
- Fields: "Name" (sign up only), "Email", "Password" with hint "At least 8 characters"
- Primary button: "Create account" / "Sign in"

## Check your email (after email sign-up)
- Title: "Check your email"
- Body: "We sent a confirmation link to {email}. Tap it, then come back here and sign in."
- Hint: "Don't see it? Check spam or promotions."
- Buttons: "Sign in", "Resend email"

## Inline errors
- "That email or password doesn't match."
- "Confirm your email first. We sent the link to {email}."
- "An account with this email already exists. Sign in instead."
- "Use at least 8 characters."
- "Enter a valid email."
- "We just sent you an email. Give it a minute, then try again."
- "Couldn't reach Plandit. Check your connection and try again."

## Settings → Account
- "Signed in as {email}" (or "Signed in with Apple")
- "Sign out"
- "Delete account" → confirmation dialog: title "Delete your account?", message "This permanently
  removes your account, saved places and plans.", button "Delete account"

## After sign-in (empty account)
A new account starts empty: no sample places or plans. Saved places from before the update carry
over into the first account made on that phone. Plans are built from places the person adds.

- Today, when nothing is planned and nothing is saved yet:
  title "Nothing planned yet", message "Add a place first. Share a TikTok or Reel to Plandit, or
  paste a link.", button "Paste a link" (opens the paste-link sheet).
- Today, when nothing is planned but places are saved (unchanged): "Tap + to turn your saved places
  into today's plan.", button "Plan a day".
- Saved, empty (unchanged): "Nothing saved yet" / "Share a TikTok or Reel to Plandit, or paste a
  link.", button "Paste a link".

## Supporting strings (added during the build)
- Generic error: "Something went wrong. Try again."
- Session expired (refresh rejected): "Your session ended. Sign in again. Your places and plans
  are still saved."
- Delete account failed: "We couldn't delete your account. Try again."
- After tapping Resend email: "Sent again to {email}."
- Profile, empty account: section title "Your profile"; streak empty "No streak yet" / "Finish a plan
  this week to start one."; past days empty "Your finished days show up here."
- Profile → Name screen: caption "What Plandit calls you.", placeholder "Your name"
- Profile streak, filled (streak = consecutive weeks with at least one finished plan; the title
  above already shows "{N}-week streak"): 1 week "A plan this week. Keep it going."; N weeks
  "A plan every week. Keep it going." (was "A plan every weekend for N weeks")
- Build without the service configured: "This build isn't set up to sign in yet. Try updating the
  app."

## Persona review (2026-11-07)
Round 1: Sofia 7 approve, Andre 7 approve, Amara 7 approve, Marcus 5 and Grace 6 approve with
conditions. Must-fix items addressed above: the welcome screen assumed existing saves (Marcus),
there was no empty-account copy (Marcus), and nothing said the app is free (Grace). Also taken from
nice-to-haves: friendlier rate-limit error, spam hint, Apple button first.
Round 2 on the revised copy: Marcus 7 approve, Grace 7 approve, no must-fix. Not taken: "paste a
Google Maps link" (the paste sheet accepts only TikTok and Instagram Reel links).
Supporting strings: Sofia 8, Marcus 8, Andre 7, Grace 7, Amara 7, all approve, no must-fix. Taken:
reassurance on session expiry, resend names the address.
Streak and not-configured strings: Sofia 8, Marcus 8, Andre 7, Grace 7, Amara 7, all approve.
Taken: matching streak lines without repeating the count; a next step on the not-configured message.
Follow-ups (nice-to-have, not in this slice): forgot password; a one-time "Your saved places came
with you" note after migration; a confirmation link that opens the app signed in; optional Name;
adding a place by typing its name (no video); "Free" placed closer to the buttons.
