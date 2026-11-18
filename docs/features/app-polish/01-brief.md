# App polish for 1.0.1: brief

Status: draft for approval, November 18, 2026. Owner: Abraham.

## Context

Plandit 1.0 was resubmitted to the App Store on November 11. Three parts of it feel unfinished:

- **The bottom bar has five items for four destinations.** Today, Saved, Plan (+), Profile and
  Settings. Settings holds only Appearance and Account (sign out, delete account).
- **Profile has dead ends.** "Notifications" and every "Recent plans" row open a screen that says
  "Coming soon".
- **Sharing takes extra work and only takes links.** Share → Plandit opens a sheet that explains
  itself and needs a "Save to Plandit" tap. A video can only be added from inside the app
  (saved-place-extraction progress: "Direct video sharing into the share extension is not
  implemented"). Once the app opens, finding the place can take 30–60 s while Render's free plan
  wakes up, with only a spinner, and a timeout fails the post.

Who it's for: mostly students who save TikToks and Reels and never act on them (Sofia, Andre).
The friend who turns the group chat into a plan (Amara) and students on a tight budget (Grace)
get a cleaner Profile and Recent plans. People with short, odd windows of free time (Marcus) only
get the easier-to-reach Plan button; this release does nothing else for them.

**Doing nothing:** 1.0 works. But the dead ends look unfinished to reviewers and students, a whole
tab holds three rows, and every share costs an extra tap with no way to share a video.

## Scope

In:

1. Bottom bar: Today, Saved, Plan and Profile (D-2).
2. Profile takes over Settings (Appearance and Account).
3. No "Coming soon" anywhere.
4. Share extension: saves straight away, accepts videos, offers Undo, and explains problems clearly.
5. In-app processing: shows what was shared while it works, says when the server is slow, retries
   once, and uses clear status words.
6. Fixes from a screen-by-screen walkthrough of the app (W requirements below).
7. The team's design feedback: a first-run tutorial, a picture-led Saved list with filter and
   sort, a reordered Profile, and the new app icon and logo (D requirements below).

Not in scope:

- Finding the place inside the share sheet (decided November 18; see Questions).
- Adding a best-guess place when Plandit isn't sure (decided November 18).
- A notifications feature. The row goes away until one exists.
- A detail screen for past plans. 1.0 doesn't store their stops, so rows show their summary inline.
- A new visual style. `docs/style_guide.md` is still pending, so this uses only the existing colors,
  type, icons and components.
- Backend, database, sync or sign-in changes; Android; the Render plan.
- Sharing a plan with friends. Today's plan text (meeting time, stops, about how much per person)
  is unchanged.

## Solution outline

- **Bar.** One rounded group with Today, Saved and Profile, and the emerald Plan (+) button on its
  own at the right. Plan is an action, not a page, and the bar now shows that.
- **Profile.** One scrolling page: who you are, Activity, Recent plans, Preferences, App
  (Appearance, how saving works) and Account (signed in as, Sign out, Delete account), then the
  logo and version.
- **Share sheet.** Choosing Plandit saves right away and shows "Saved to Plandit" with the post's
  creator and caption when the share included them. It closes by itself after about 2 s; Done
  closes it sooner, and Undo takes it back. Videos from Photos, Files or any app work the same way.
- **In the app.** The next time Plandit opens, it goes to what you shared and shows the post (who
  posted it and what it said) while it finds the place. It retries once if the network fails,
  explains when the server is slow, and either adds the place (exact address match), asks you to
  pick from up to three, or asks for the name or address.

## Requirements

### Navigation

- **NAV-1** *(Replaced by D-2.)* The bottom bar shows exactly three tabs, Today, Saved and Profile, in one group, and a
  separate emerald Plan button at the trailing end that opens the planner.
- **NAV-2** There is no Settings tab. Launching with `-startTab settings` opens Profile.
- **NAV-3** The selected tab keeps its sliding highlight and selection haptic. VoiceOver reads
  "Today", "Saved", "Profile" and "Plan a day". Every target is at least 44 pt. At the largest
  standard Dynamic Type size, labels may shrink but don't clip or wrap.
- **NAV-4** On iPad the same bar appears inside the panel.

### Profile

- **PRO-1** *(Order replaced by D-6.)* Profile shows, in order: header (initial, name or "Your profile", school, signed-in
  email), Activity, Recent plans, Preferences (Name, Default budget, Home base, Getting around), App
  (Appearance, Saving from TikTok and Instagram), Account (signed in as, Sign out, Delete account),
  then the logo and version.
- **PRO-2** Nothing opens "Coming soon". The Notifications row is gone. Recent plan rows show the
  date, number of stops, the cost per person in dollars (never "$$") and, when the plan recorded
  its budget, whether it stayed under it and by how much ("$22 under"). If the cost includes subway and bus fares, the row says
  so. Rows don't navigate and show no chevron.
- **PRO-3** Sign out and Delete account behave exactly as in 1.0: the same confirmation dialog, the
  Apple re-authorization for Apple accounts, and token revocation. Errors show under Account.
- **PRO-4** Appearance works as in 1.0 and opens from Profile.

### Share sheet

- **SHR-1** Choosing Plandit for a supported TikTok or Instagram Reel link saves it without another
  tap and shows "Saved to Plandit", with the platform and, when the share included them, the creator
  and caption, and the line "Plandit finds the place next time you open it." The sheet closes by
  itself after about 2 s, or at once on Done.
- **SHR-2** Undo on that confirmation removes the share, and any copied video, before it reaches
  the app.
- **SHR-3** Sharing a video file from Photos, Files or another app saves it the same way. The video
  is copied only into Plandit's own storage on the phone, is never uploaded, and is deleted after
  it's read, or after 24 hours if it never is.
- **SHR-4** An unsupported link, a share with no link, or a video that's too large or isn't a video
  shows a plain message and a Close button. Nothing is saved. Messages name what works: "a TikTok,
  an Instagram post or Reel, or a video".
- **SHR-5** While VoiceOver is on, the confirmation stays until Done or Undo.
- **SHR-6** Sharing the same link twice leaves one saved post, and the confirmation still says it's
  saved.

### Finding the place

- **PRC-1** When Plandit opens with new shares, it shows them: one share opens that post, several
  open Saved with the new ones on top. If the sheet is at its lowest height, it rises to half.
  Several shares are looked up at the same time, and each row fills in as it finishes. With no new
  shares, Plandit opens where it always does and never jumps to Saved.
- **PRC-2** While Plandit looks for the place, the post shows where it came from (platform, creator,
  caption and thumbnail when known) and a progress line. After 8 s it adds "Still looking. This can
  take up to a minute."
- **PRC-3** A network error or timeout is retried once on its own before the post shows "We
  couldn't find a place" with Try again.
- **PRC-4** A shared video is read on the phone. It ends the same ways a link does. If reading fails,
  the post stays and asks for the place's name or address; it doesn't disappear.
- **PRC-5** The Saved list uses these status words: "Finding…", "Pick the place", "Add the place",
  "Check this place", "Couldn't find it", "In plan".
- **PRC-6** The confidence rule doesn't change: only one exact-address match is added on its own.
  Otherwise the user picks from up to three places.
- **PRC-7** When a place is added, by match or by pick, the phone gives a success haptic and the
  post offers "Add to today's plan".
- **PRC-8** A video post that was still processing when the app quit asks to share the video again
  or add the place's name. It doesn't fail as an unreadable link.

### Walkthrough fixes

From a walkthrough of 91 screens on November 18 (iPhone 17 Pro, iOS 26, light and dark, plus
iPad mini). None adds a sign-up wall or a trial, or replaces a real price with a range.

Shell and Profile:

- **W-1** Nothing is hidden under the bottom bar. On every screen inside the sheet (Today, a stop,
  Saved, a saved post, Profile, the empty Today), the last item scrolls fully above the bar at
  half and full height. In 1.0, "Remove from plan", Profile's logo and version, Today's last stop
  and the empty state's "Plan a day" sit under it.
- **W-2** *(No longer applies: D-6 drops these numbers.)* Profile's "Walked" and "Under budget" count only plans that recorded them. When none
  did, they show "–" and the line "Older plans didn't record this." In 1.0, 3 plans at $31, $38
  and $12 against $60 show "0 of 3 under budget" and "0.0 mi walked".
- **W-3** The sign-in screen shows the "At least 8 characters" hint only when creating an account.
- **W-4** On iPad, the Welcome screen's text and buttons are at most about 440 pt wide and
  centered, and the map behind Saved and Profile shows Manhattan beside the panel (today it shows
  Newark).
- **W-5** The Delete account confirmation has a Cancel button.
- **W-6** The Name screen says changes save on their own.
- **W-7** One name for the feature: "Save from TikTok and Instagram" in the Saved tip and in
  Profile.
- **W-8** Appearance has its own icon instead of the Settings gear.

Saved and sharing:

- **W-9** A status ("In plan", "Pick the place") never truncates a saved place's name.
- **W-10** Saved dates read the same way: "Today", "Yesterday", "3 days ago" up to 6 days, then
  "Nov 6".
- **W-11** Add a link: a top bar with Cancel, a fully visible placeholder, no text cut off
  mid-sentence, and the Save button never hidden by the keyboard.
- **W-12** A post Plandit couldn't place shows one clear screen: a title, a name-or-address search
  that starts empty (not filled with the link), and "Use the video instead" as the second choice.
  Captions never show the post's link.
- **W-13** "Places found" matches the source ("from this TikTok", not "from the video"), and
  "Remove from saved" moves to the bottom of the screen.
- **W-14** "Choose from Photos" and "Choose from Files" look like the same kind of button.

Sheets and Today:

- **W-15** Sheet headers (Budget, Plan a day, costs, travel) stay solid while content scrolls
  under them, without blurred text showing through.
- **W-16** When a day has no walking, Today's summary shows its rides by kind ("2 subway rides",
  "1 subway, 1 bus") instead of "0.0 mi Walking".
- **W-17** Today's times agree everywhere: a stop never starts before the earliest arrival its Time
  sheet shows, and a trip shows the same minutes in the timeline and in the travel sheet. In 1.0
  they disagree by 1 to 3 minutes. This waits for Eldad's PR #28, which changes the same code, and
  is rechecked after it merges. If #28 hasn't merged when 1.0.1 is cut, 1.0.1 ships without W-17,
  and it moves to 1.0.2 as an open item in the progress file.

Seen but not in scope: overlapping map pins (first candidate for the next release), the dark
map's tint (a style-guide call), system context menus drawn over the bar, and the planner putting
a "late lunch" after dinner (planner logic; a GitHub issue for Eldad).

### Design feedback (D requirements)

From the team's "App Design Feedback" document, the "Images for the app" folder and the new app
icon, added by Abraham on November 18 after he approved this brief. Where a D requirement and an
earlier one disagree, the D requirement wins; the earlier one is marked.

First-run tutorial:

- **D-1** A brand-new account sees a three-page tutorial once, right after it's created and before
  the map. A new account is one with no saved data on the server or the phone. Pages, each with
  Skip at the top right and Continue at the bottom:
  1. "Share the saved places you want to visit". "Add a place from Instagram or TikTok."
  2. "Tell us what you want your day to look like". "Pick your saved places, then set your time
     and budget." (The draft said "time, budget, and starting point"; the planner doesn't ask for a
     starting point.)
  3. "Get a plan for your day". "See your stops in order and how to get between them."

  The pictures follow the draft's three drawings (a saved post with a bookmark, three sliders, a
  map grid with a dotted route), drawn in the app's existing colors. They're swapped for the
  designer's files if those arrive. Skip on any page closes the whole tutorial and opens the map in
  one tap, and it's never shown again. Existing accounts don't see it, including on a new phone. The
  one exception: an existing account whose first sign-in on a new phone can't reach the server
  (offline, or Render still waking) looks new, so it sees the tutorial once. That's accepted, because
  a brand-new account often meets a waking server and should still get the tutorial.

Bottom bar:

- **D-2** One bar with four items in this order: Today, Saved, Plan, Profile. Plan is the third
  item, an emerald "+ Plan" pill, as in the draft. The selected tab gets a tinted highlight.
  VoiceOver still reads Plan as "Plan a day". This replaces NAV-1's separate Plan button.

Saved:

- **D-3** Across the top, a row of category pictures (the watercolor images): Food, Coffee,
  Activity, Outdoors, Nightlife, Culture and Others (shopping and anything else). Only categories
  with at least one saved place appear. Tapping one shows only that category; tapping it again
  shows all.
- **D-4** Under the pictures, two menus: Filter (All, Free only) and Sort (Newest, Oldest). Free
  means the place's cost in Plandit is $0, as set by the user or as Plandit estimates it (parks are
  free).
- **D-5** Each row shows only the place's name and "Category · Neighborhood", plus "· Free" with a
  star when it's free. On the right: "In plan" with a check when the place is in today's plan,
  otherwise a + button that adds it to today's plan in one tap, with a success haptic and no
  confirmation (with no plan yet today, it starts one or opens the planner with the place picked;
  it never looks like nothing happened), then a chevron. The draft's "Added" became "In plan"
  because everything in Saved has already been added to Saved. No
  thumbnail, source line, date or price. A post that isn't a place yet shows its status word
  instead of the + (PRC-5).

Profile:

- **D-6** Profile shows, in order:
  1. The header: initial, name or "Your profile", and school. Tapping it edits the name.
  2. Preferences: Home base, Default budget ("$30 per person"), Preferred transportation,
     Appearance, and How it works ("Saving places from TikTok and Instagram").
  3. Activity: the NYC skyline picture above three numbers: Plans completed, Neighborhoods
     explored (distinct neighborhoods of places in completed plans) and Places saved.
  4. Past plans: inline rows (PRO-2).
  5. Account: Signed in as, Sign out, Delete account.
  6. The logo and version.

  This replaces PRO-1's order. The Walked, Under budget, Average and Streak numbers go away, so
  W-2 no longer applies. The draft's Notifications row stays out (PRO-2). Its chevrons on past
  plans stay out too, because 1.0 didn't save their stops.

Logo:

- **D-7** The app icon is the new glossy white "P" on green, full-bleed. iOS rounds the corners.
  The same icon is used in dark mode.
- **D-8** In the app, the new mark replaces the old one on the splash screen, Welcome, Profile's
  footer and the share sheet, next to the word "Plandit".

Not in scope from the feedback:

- The Home tab with lists of places (Change 3). It waits for 1.0.2, when the designer's lists
  arrive and the planner-vs-feed rule in AGENTS.md is settled (Abraham, November 18).
- Past plan detail screens.
- The drafts' dark-only look and turquoise Plan button. The app keeps its light and dark colors
  and its emerald.
- Sending the new logo to the website (Jaden's repo) and the App Store listing art beyond the icon
  that ships in the build.

## Analytics and logging

No new events. `linkSaved` still fires once per post that stays, including shared videos, and
`placeSaved` once per added place. Nothing new is logged on the server.

## Rollout

- Ships as 1.0.1: TestFlight internal group first, then App Store review. No feature flags.
- Before submitting 1.0.1:
  - the privacy, terms and support pages say "Profile → Account → Delete account" instead of
    "Settings → Account → Delete account". The live site is Jaden's repo, so it needs his PR merge;
  - the App Store description's "delete your account … any time in Settings" says "in your
    Profile";
  - the App Review notes say "Profile > Delete account".
- Persona gate: the five persona agents review this brief and the new copy. A `must_fix` blocks.

## Questions

| Question | Answer | When, who |
|---|---|---|
| Where does Plan sit in a four-item bar? | Separate button at the right, next to a three-tab group. Replaced the same day by the design draft (D-2). | Nov 18, Abraham |
| Where is the place found after a share? | In the app. The share sheet saves instantly and closes; the app finishes. | Nov 18, Abraham |
| What happens when Plandit isn't sure which place a post means? | Ask the user to pick (unchanged rule). | Nov 18, Abraham |
| Inline Account section or Settings behind a gear? | Inline, so Delete account is one scroll from Profile. | Nov 18, proposed in this brief |
| Is the visual style changing? | Only where the team's design feedback says so (D rows): watercolor category pictures, the skyline, the new logo. Colors, type and components stay. | Nov 18, Abraham's feedback document |
| Replace Today with a Home tab of lists? | Not in 1.0.1. Home waits for the lists and the planner-vs-feed decision (1.0.2). | Nov 18, Abraham |
| Where does Plan sit now? | Third item in a four-item bar, per the design draft (replaces the separate button). | Nov 18, from the feedback document |
