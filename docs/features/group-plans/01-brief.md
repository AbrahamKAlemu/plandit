# Group plans: brief

Status: draft for approval, November 21, 2026. Owner: Abraham. Design only; nothing is built until
Abraham approves this dossier.

## Context

Plans with friends die in the group chat. Someone suggests a day, three people reply with
different budgets and times, nobody decides, and it never happens. Plandit 1.0.1 lets a student
send their plan as a link that friends open in a browser (#37), but the page is read-only: friends
can't say they're coming, can't push back on a stop, and the organizer still has to collect
everyone's budget and free time by hand.

Abraham asked for three ways to plan together, all of them:

1. **Answer the plan link.** Friends open the link the organizer already sends, tap "I'm in" or
   "Can't make it", and can mark a stop they'd swap. No app or account.
2. **Friends add what works for them.** The organizer sends a link before there's a plan. Friends
   enter their budget and free time, and star the places they want most from a short list the
   organizer picked. The organizer's app builds one plan that fits everyone.
3. **Edit one plan together in the app.** Friends who have Plandit accounts join a plan and see
   each other's changes.

Who it's for: mostly Amara, the friend who turns the group chat into a plan, and Grace, whose
budget is usually the lowest in the group. Sofia and Andre benefit when they're the organizer.
Marcus mostly receives links; mode 1 and 2 ask him for three answers and no download.

**Doing nothing:** students keep sending read-only links and sorting out the rest in the group
chat. The single-person planner keeps working.

**Product guardrails:** this is still a planner. Friends only see and star places the organizer
chose; there's no feed, no public profiles and no messaging. Budget stays a core input. In mode 1,
friends see the per-person cost, with fares, before they say yes. In mode 2, each person gives
their own budget and the plan fits the lowest.

## Scope

In:

1. Mode 1 on the existing plan page (plandit.app/p/…): "I'm in", "Can't make it", "I'd swap this"
   on a stop, with a first name. The organizer sees the answers in Today.
2. Mode 2: a new "Ask friends what works" link (plandit.app/g/…) with up to 10 places, a day and
   a time range. Friends answer three questions. The organizer's app builds the plan from the answers and
   the link turns into the mode 1 page.
3. Mode 3: a plan stored on the server that up to 8 Plandit accounts can edit. Changes show up
   within about 15 seconds while the app is open.
4. The privacy, safety and abuse protections that come with letting people who aren't users write
   to Plandit.

Out (not in this feature):

- Push notifications, email or texts. Nobody is notified; the organizer sees answers when they
  open the app, and the group chat stays the way people tell each other.
- Chat or comments. The only free text is a first name.
- Splitting costs or paying each other.
- Friends searching for places that aren't on the organizer's list.
- Public groups, discovery of other users, or adding people who don't have the link.
- Real-time sync (WebSockets or Supabase Realtime). The app checks for changes while it's open.

## Solution outline

### Mode 1: answer the plan link

The page keeps what it shows now at the top: the time, the first stop and the per-person cost.
Under the stops it gets a short form: a first name and two buttons, **I'm in** and
**Can't make it**. Next to each stop is **I'd swap this**. When the organizer included swap
options while sharing, the friend picks one, for example "Prince Street Pizza instead". Under the
title the page shows who's coming: "Maya, Jordan and 1 more are in".

A friend can change their answer from the same browser. The page remembers them with a cookie for
that link only.

In the app, Today shows "3 in · 1 can't make it" under the share button, and a small mark on
stops friends would swap ("2 would swap"). Tapping it shows who and what they picked, with
**Swap it** (the planner replaces the stop and replans the times) and **Keep it**. The organizer can
remove any answer. Updating the plan keeps the link and the answers. An answer about a stop that's
no longer in the plan disappears.

When sharing, the organizer sees "Let friends suggest swaps", on by default. With it on, Plandit
adds up to two of the organizer's saved places per stop: nearby, the same kind of place, open then,
and within budget. The share preview lists them before anything is sent.

### Mode 2: friends add what works for them

In the planner, **Ask friends what works** asks the organizer for:

- up to 10 saved places;
- a day and a time range, for example "Saturday, 12–8 PM";
- "Answers by", for example "Friday 9 PM". For a plan today, it starts at 2 hours from now.

They get a link to send. A friend who opens it sees the places (name, neighborhood, kind and the
cost in dollars, such as "$6" or "Free") and "Answers by Friday 9 PM". Then they answer three
questions:

1. **Your budget for the day, train included** (a slider, $0 to $150);
2. **When you're free** (from and until, set to the organizer's whole range to start with);
3. **Star up to 3 places** you want most.

Plus their first name.

The organizer's app lists the answers ("4 answered"). The organizer can tap **Build our plan** at
any time, with whoever has answered; they don't have to wait for the deadline. Before building, it
shows the budget the plan will use ("Budget: $20 each"), without saying whose it is. The plan
uses:

- the time everyone is free: the latest "from" to the earliest "until";
- the lowest budget, so the plan is affordable for everyone (Grace);
- places in order of stars. The planner tries to fit the most-starred places first.

If times don't overlap, the app shows whose times clash and lets the organizer leave someone's
times out. The built plan goes to Today and is shared on the same link, which now shows the plan
with mode 1's "I'm in".

### Mode 3: edit together in the app

The organizer taps **Edit with friends** on today's plan or a plan for a later date. Plandit makes
it a group plan and gives an invite link. A friend with Plandit opens the link. In this version
that means pasting it into Plandit's "Add a link", or sharing it to Plandit from Messages. They
see "Join Maya's plan for Saturday? Your first name will show to the group" and join.

Everyone in the group sees the plan in Today, with the members' initials. Anyone can add, remove
or reorder stops, change a trip's travel mode, or check off a stop. The app checks for changes
every 15 seconds while the plan is on screen, and when the app opens. If two people change the
plan at once, the second change is applied on top of the first. If it can't be (the stop it
touched was removed), the app says "Maya removed that stop" and shows the latest plan.

The organizer can remove members and end the group. Anyone can leave. When the day ends, the plan
goes into each member's Past plans as usual.

## Requirements

### Mode 1: answer the plan link (GV)

- **GV-1** The plan page shows "I'm in" and "Can't make it" with a first name (1 to 30
  characters). No sign-in.
- **GV-2** Each stop has "I'd swap this"; when the organizer included swap options, the friend
  can pick one of them.
- **GV-3** The page shows how many are in and up to 3 first names ("Maya, Jordan and 1 more are
  in"). "Can't make it" names aren't shown on the page.
- **GV-4** The same browser can change or take back its answer; another browser can't change it.
- **GV-5** The organizer sees answers in Today within one refresh: counts, names, and per-stop swap
  picks. Opening Today or the app refreshes.
- **GV-6** "Swap it" replaces the stop with the picked place and replans times from that stop on,
  as editing a plan does now. Undo works.
- **GV-7** The organizer can remove an answer; it disappears from the page and the app.
- **GV-8** Updating the plan keeps answers; answers about removed stops are dropped.
- **GV-9** Swap options are only places the organizer saved, are listed in the share preview
  before sending, and can be turned off.
- **GV-10** Stop sharing deletes the answers with the link.
- **GV-11** A friend's first tap on a link (`/p/` or `/g/`) shows the page within 3 seconds on a
  phone, even after the server has been idle for hours. Mode 1 doesn't ship until this holds (see
  Q-1 for how).
- **GV-12** The time, the first stop and the per-person cost stay at the top of the page, above the
  form.

### Mode 2: friends add what works for them (GI)

- **GI-1** The organizer picks 2 to 10 saved places, a day (today to 14 days out), a time range of
  at least 1 hour, and an answer deadline (2 hours from now by default for a plan today). They get a
  link.
- **GI-2** A friend sees each place's cost in dollars and the deadline. They answer with a first
  name, a budget ($0 to $150, labeled "train included"), a free window inside the range (starting
  at the whole range), and up to 3 starred places. No sign-in. They can change it from the same
  browser until the deadline.
- **GI-3** After the deadline, or after the organizer builds the plan, the link stops taking
  answers and says so.
- **GI-4** The organizer sees each answer: name, budget, window and stars.
- **GI-5** "Build our plan" plans between the latest "from" and earliest "until" of everyone
  included, with the lowest budget among them (fares count against it), trying the most-starred
  places first. The organizer is included with their own default budget and the full range unless
  they change it. The organizer can build at any time with whoever has answered. Before building,
  the app shows the budget it will use, without naming whose it is.
- **GI-6** If the windows don't overlap by at least 1 hour, the app names the people whose times
  clash and lets the organizer leave any of them out of the time calculation. Nothing is planned
  silently over someone's window.
- **GI-7** The built plan goes into Today (or that day's plan), and the same link now opens the
  mode 1 page for that plan.
- **GI-8** A friend's page never shows other friends' budgets or windows; it shows only how many
  have answered.

### Mode 3: edit together (GE)

- **GE-1** The organizer can turn a plan into a group plan and get an invite link. Up to 8 members
  including the organizer.
- **GE-2** A signed-in Plandit user who opens or pastes the invite link sees the organizer's first
  name, the date, and that their first name will be visible, then joins with one tap.
- **GE-3** Members see the plan in Today with members' initials, and can add, remove and reorder
  stops, change travel modes and check off stops.
- **GE-4** A change shows on other members' phones within 15 seconds while the plan is on screen,
  and when the app opens.
- **GE-5** Two changes made at the same time both apply when they touch different stops. When they
  can't (one removed the stop the other changed), the later one is not applied, and its author sees
  who changed what.
- **GE-6** A group plan doesn't replace or overwrite the member's own plan for that day. When both
  exist, Today lets them switch between "Mine" and the group's.
- **GE-7** The organizer can remove a member and end the group. Anyone can leave. A member who
  leaves or is removed stops seeing the plan at the next refresh.
- **GE-8** Invite links can be turned off and replaced by the organizer; the old one stops working.
- **GE-9** After the day ends, each member gets the plan in Past plans and the visited places on
  their map, as with their own plans.
- **GE-10** Deleting an account removes its memberships, and ends the groups it organized.

### Safety, privacy and abuse (GS)

- **GS-1** Every new table has row level security on (the test from #41 enforces it), and every
  API endpoint for groups returns 404 to anyone who isn't the owner or a member.
- **GS-2** Public answer forms are limited per IP address and per link: 20 answers per IP per hour,
  50 answers per link. Over the limit, the page says to try later.
- **GS-3** Public forms are protected against cross-site posting (Django's CSRF token) and the pages
  have a Content Security Policy that only allows Plandit's own scripts and the Google font.
- **GS-4** First names are 1 to 30 characters of letters, spaces, hyphens and apostrophes, checked
  against a short blocklist of slurs. The organizer can remove any answer (GV-7). The pages have a
  "Report this page" link to Plandit's support address.
- **GS-5** Answers from friends (names, budgets, windows, stars, swap picks) are deleted 30 days
  after the plan's date, or with the link, whichever is first. Group plans are deleted 30 days
  after their date.
- **GS-6** The privacy policy and terms on plandit.app describe what friends enter, who sees it and
  when it's deleted, before the app version with these features is submitted.
- **GS-7** Friends' answers and group plans are never used for suggestions, metrics about
  individuals, or anything else beyond the plan.

### Copy (GC)

- **GC-1** The text in this brief ("I'm in", "Can't make it", "I'd swap this", "Ask friends what
  works", "Build our plan", "Edit with friends") is reviewed by the persona agents before build.
  A `must_fix` blocks it. None of the words AGENTS.md rules out for headlines appear.

## Analytics and logging

No new app events. The server counts from its own tables, in the class metrics:

- links with at least one answer;
- answers per link;
- mode 2 links and how many got built;
- group plans with 2+ members;
- edits per group plan.

No names or answer contents are logged. Request logs keep their current format, which has the
path, so link slugs appear in Render's access log, as they do now for /p/ links.

## Rollout

Each mode ships as a backend slice, then an iOS slice. The backend goes first and does nothing
until an app uses it (see the plan). Mode 1 is useful alone and ships first. Modes 2 and 3 follow
in later app versions.

The website's privacy and terms change before the first app version with mode 1 is submitted
(GS-6). App Review: user-generated content is already "Yes" from 1.0.1. The Review Notes describe
answers, groups, the limits and the report link, and the demo setup gets a seeded group (plan
"Rollout").

## Questions

Open (for Abraham):

- **Q-1 How to meet GV-11.** Render's free plan sleeps after 15 idle minutes, and then the first
  request takes 30 to 60 seconds. Three personas made a fast first load a must-fix, so GV-11 is a
  requirement; the open part is how to meet it.
  - **Render Starter, $7 a month.** It doesn't sleep. This is the recommendation.
  - **A keep-awake ping from an outside scheduler.** Free, but it needs a new service, and it works
    against the free plan's intent.

  Either way it's a paid or new service, so it's Abraham's call. Mode 1 waits for it.
- **Q-2 Names on the page.** The page shows up to 3 first names of people who are in (GV-3). The
  safer option is counts only ("3 are in"). Recommendation: names, because seeing who's coming is
  what makes people say yes, and the link only lives in the group chat. Sofia, Andre and Amara all
  asked for names.
- **Q-3 Universal links.** Mode 3's invite opens in Plandit only by pasting or sharing it to the
  app. Opening it straight from Messages needs universal links: an
  `apple-app-site-association` file on the link's domain (plandit.app is on Jaden's Vercel
  project) and a new app entitlement. Recommendation: do it as a follow-up slice once mode 3 is in
  use.
- **Q-4 Throttle storage.** Today's cache is per process and resets when Render sleeps, so the
  per-IP limit is weak. Django's database cache needs no new service. Recommendation: use it for
  these limits only.
- **Q-5 Order.** Recommendation: mode 1, then 2, then 3, one app version each. Mode 3 is the
  largest and the only one that needs both people to have the app.

Resolved:

- All three modes are in scope (Abraham, November 21).
