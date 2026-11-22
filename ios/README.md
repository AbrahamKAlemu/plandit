# Plandit (iOS)

SwiftUI scaffold for Plandit: turn saved TikToks and Reels into a real day plan in Manhattan.

The app copies Find My's layout. A full-screen Manhattan map sits behind a sheet that never closes. The tab bar lives inside that sheet. Each tab swaps both the sheet's content and the map's layers.

| Tab | Sheet | Map |
| --- | --- | --- |
| **Today** | The Plandit day: summary (time, budget, walking), directions to the next stop, and the stop-by-stop timeline. Tap a stop to open its details. | Numbered stops and the route. Walking legs are solid lines, transit legs are dotted, driving legs are dashed (walking and driving follow real streets). The active leg is emerald. |
| **Saved** | Posts shared from TikTok, Instagram or the web, with their extraction status, category filters, and a "paste a link" sheet. | One pin per mapped saved place. |
| **Profile** | Profile, stats, recent plans, preferences (placeholders for now). | Dots for places from past plans. |

## Setup

Requirements: Xcode 26 or later, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
cd ios
xcodegen generate     # rerun after adding or removing files
open Plandit.xcodeproj
```

1. Set your team in `project.yml` (`DEVELOPMENT_TEAM`) or in Xcode → Signing & Capabilities, for both targets.
2. If you change the bundle IDs (`com.plandit.app`, `com.plandit.app.share`), also change the App Group `group.com.plandit.app` in `project.yml` (in both entitlements blocks) and in `Shared/Sharing/ShareInbox.swift`.
3. Run the **Plandit** scheme. Deployment target: iOS 17.

For an archive that uses production link extraction, set these build settings without committing
private provider credentials:

| Build setting | Value |
|---|---|
| `PLANDIT_API_BASE_URL` | HTTPS URL for the deployed Django API |
| `PLANDIT_SUPABASE_URL` | `https://<project-ref>.supabase.co` |
| `PLANDIT_SUPABASE_ANON_KEY` | Supabase's public client key |

Anonymous sign-ins must be enabled in the Supabase project. The public key is embedded in the app;
the EnsembleData token remains only on the server. If any value is absent, release builds fall back
to TikTok oEmbed rather than sending an unauthenticated provider request.

Dev launch arguments (Scheme → Run → Arguments): `-startTab saved|profile` and `-startDetent peek|large`.
Debug builds also take `-seedShares 1|2|3`, which queues sample TikTok shares the way the share
extension does, and `-fakeExtraction slow|fail|match|pick`, which stands in for the backend
(`slow` answers after 30 s, `fail` times out, `match` adds Levain Bakery on its own, `pick` offers
three places). The UI tests in `ShareFlowTests` use both.

Appearance follows the device by default. Open **Profile → Appearance** to choose
System, Light, or Dark; the preference also applies to the share extension.

### Testing Share → Plandit

You need a signed build with the App Group capability. On a device, or in a simulator with Safari: open a TikTok or Instagram link, tap Share, then **Plandit**. There is no Save button: the share is saved as soon as the sheet opens, which then says "Saved to Plandit" and closes by itself after 2 seconds (it stays open while VoiceOver is on). **Undo** takes the share back before the app sees it.

Videos work too: share a video from Photos or Files (up to 250 MB). The extension copies it into
the App Group's `TemporaryMedia` folder; it never leaves the device. The app reads the video's
on-screen text and speech, then deletes the copy. A copy that is never read is deleted after
24 hours, by the extension or the app, whichever runs first. Unsigned builds have no App Group, so
they can't take videos from other apps.

When you switch back to Plandit, it reads the shared inbox. One new share opens its post; several
open Saved. Each post shows what was shared while Plandit finds the place.

## Layout

```
Plandit/            App target
  App/              Entry point, RootView (map + persistent sheet), tabs/router, UIKit appearance
  DesignSystem/     Components (headers, chips, badges, cards) and the tab bar
  Features/
    Map/            Map view, pins, Manhattan camera framing (MapViewport)
    Today/          Plandit day sheet, timeline, stop detail
    Saved/          Saved list, post detail, add-link sheet
    Profile/        Profile and stats
  Models/           Place, DayPlan, SavedPost, UserProfile, SampleData (mock)
  Services/         PlanditStore (state), RouteService (Apple Maps walk/transit/drive times and paths), PlaceExtractor
PlanditShare/       Share extension: hosts the share sheet; saves a link, text with a link, or a video
Shared/             Code and assets compiled into both targets
  DesignSystem/     Color tokens, Manrope type scale, spacing, Lucide Icon, BrandArt, button styles
  Sharing/          ShareInbox (App Group handoff), ShareIntake (reads what was shared), the share
                    sheet's view, TemporaryMediaStore (shared videos), link parsing, SourcePlatform
  Fonts/            Manrope 400–800 (OFL)
  SharedAssets.xcassets   Brand/ (official logo SVGs) and Icons/ (Lucide)
Design/Logo/        The full logo package, copied unchanged from the design team
```

## Design system

Everything follows the *Plandit Style Guide* (October 2026):

- **Color:** `Shared/DesignSystem/Colors.swift`. Emerald marks the single most important action. Ink is for structure. Red is used only for errors and unavailable states. No gradients, no glass.
- **Type:** Manrope via `Font.pageHeading`, `.cardHeading`, `.bodyText`, `.label`, `.metadata`, and so on (the mobile scale from the guide).
- **Icons:** Lucide, through `Icon(.clock)`. To add one, put the SVG from lucide.dev into `Shared/SharedAssets.xcassets/Icons` with stroke width 1.75 and template rendering. The one exception is Saved's category tiles, which use Phosphor duotone icons from `Plandit/Resources/Assets.xcassets/Categories`. Everything else stays Lucide. Don't use SF Symbols in product UI.
- **Logo:** `BrandLockup` is the logo in the app (splash, Welcome, the first-run tutorial, Profile's footer): the mark, `BrandArt.markSquare`, beside the word "Plandit" drawn in Manrope ExtraBold. `markSquare` is a PNG of 1.0.1's glossy white "P" on a green tile; the share extension shows it on its own. The other `BrandArt` images are 1.0's SVGs.
- **Buttons:** `.buttonStyle(.primary)` (emerald fill, ink label) and `.secondary` (ink outline).

Asset sources:
- 1.0's logo SVGs come from `Design/Logo`. The 1.0.1 mark and app icon come from the glossy "P" artwork.
- The app icon is `AppIcon-1024.png`: one 1024×1024 PNG with no alpha, full-bleed because iOS applies its own corner mask. There's no dark variant.
- Lucide icons are ISC licensed and came from `lucide-static@0.469.0`.
- The category icons on Saved are Phosphor duotone, MIT licensed, from `@phosphor-icons/core@2.1.1` (the set SVG Repo hosts).
- Manrope is OFL licensed. The static weights were instanced from the Google Fonts variable font.

## Flows worth knowing

- **Share → Plandit → app:** when the app comes back to the foreground it drains the share inbox, switches to Saved, and opens the new post so you can watch it get mapped (several new shares open Saved instead, and a collapsed sheet comes up to half height). New shares are looked up side by side, not one after another; a lookup that fails is retried once after 2 seconds. A lookup cut off when the app quit starts again on the next launch. Pasting a link does the same.
- **+ → Plan a day:** the emerald + in the tab bar (on every tab) opens the planner. Pick saved places (each shows when it was saved), set a start time, an optional "Free until" and a budget, and a live preview shows the order, times, cost and anything left out (closed, over budget, or past the end of the day). "Add to today" keeps stops that are done or underway and re-orders the rest with the new picks; "Start over" replaces the day. The logic lives in `Services/DayPlanner.swift`; `backend/plandit/plans/planner.py` follows the same rules. Launch with `-openPlanner YES` to start in the planner.
- **Add to today:** a saved place goes into the best open slot among the stops still ahead, not just the end. It tries every slot and picks the one where the place is open and nothing else ends up closed, with the least extra travel and the least added time (ties go to the latest slot). Later stops only move as much as they have to; a visit that can't fit ends at closing, and the post screen says "Stop 4 · 2:30–3:15 PM" plus any closing or budget warning. The logic is `DayPlan.inserting` in `Models/PlanEditing.swift`.
- **Running behind?** When a stop's planned time has been over for 10 minutes and it isn't marked done, Today shows a card: "Mark them done" (they're done; the stop whose time has started becomes Now) or "Start from now" (a stop underway runs until now, otherwise the first missed stop starts now; the rest of the day moves by the same amount). Logic: `DayPlan.overdueStops`, `markOverdueDone`, `startRestFromNow`. Debug builds take `-clock 16:00` to pin the time for UI tests.
- **Post screen:** once a saved place is in today, it shows the stop number and time, the trip there ("23 min walk from The Met"), any warnings, and **Remove from today** (keeps it in Saved).
- **Edit plan:** Today's **Edit** button opens a list of the stops still ahead: drag to reorder, tap the trash can to remove. Stops done or underway stay put. Times are redone one after another from the first stop's slot (evening spots wait for 8 PM), shown as "2:20 PM · was 1:15 PM" before Save, with closing warnings. Trips between stops that stay neighbors keep the way the user picked. Logic: `DayPlan.edited(keeping:)` and `reordered`.
- **Undo:** "I'm here", "Done here", removing, editing, adding, changing a time, catching up and building a plan each put a bar above the tab bar for 6 seconds ("The Met is done · Undo"). It restores the plan from just before (`PlanditStore.undo`).
- **Stop status:** the top of a stop's screen has a Planned / I'm here / Done switch. Any choice can be changed back with one tap (`store.leave`, `arrive`, `complete`).
- **Share plan:** the share button on Today and **Share plan with friends** under the stops open a sheet. First choice is a link (`plandit.app/p/<slug>`): a page friends open in the browser, no app needed. **Create link** posts `DayPlan.sharedPayload` to `POST /api/shares/`; the link is kept with the plan (`PlanditStore.sharedLink`, in the snapshot), and a change to a shared plan republishes the page about 2 s later, only if what the page shows changed. **Stop sharing** deletes it. Below, **Send as a text instead** keeps the text message (`DayPlan.message(_:)`; `shareText` is its short form). UI tests use `-fakeSharing` (or `-fakeSharing fail`) since `-skipAuth` has no server.
- **Friends' answers:** the page also sends each stop's id, the plan's date and, with **Let friends suggest swaps** on, up to two saved places per stop that fit (`SwapOptions`: same kind, within 1.2 mi, open then, on budget). Friends tap I'm in or Can't make it and can pick a swap. Today reads `GET /api/shares/<slug>/answers/` when the plan shows and when the app comes back (at most every 10 s; a 404 means no answers) and shows "2 in · 1 can't make it" and "n would swap" on a stop. **Swap it** replaces the stop in place (Undo puts it back). Undo restores the plan and its page but not friends' swap picks for the replaced stop, which the server drops once the page updates (GV-8). **Keep it** hides those picks (`SharedLink.keptSwaps`), and the answers sheet removes an answer from the page too. Answers stay in memory only. UI tests add `-fakeAnswers` to `-fakeSharing`.
- **Stop times:** tap **When** on a stop to change its start and how long you stay; later stops move with it or only when they'd overlap (`DayPlan.setTime`).
- **Getting there:** every trip still ahead on Today has a **Change** button. It opens walk / subway / drive with Apple Maps times (estimates offline), cost, and arrival time; picking one moves later stops by the difference (evening spots still wait for 8 PM) and warns if you'd arrive after a place closes. Drive is a taxi or rideshare (about $4 + $3.50/mi, $10 minimum, plus 5 minutes for pickup). "Directions in Maps" opens Apple Maps in that mode, including real subway lines. The logic is `DayPlan.setLeg` and the "Getting between stops" part of `PlanditStore`.
- **Budget:** tap the money number on Today. Every stop shows its price and where it came from: the saved post's price, or a typical NYC range for its category (`Models/Pricing.swift`) when the post didn't say. Users can type their own number, list items that add up, add day-level "Other costs", and change the budget. A saved place's own price (set on its detail screen) is used whenever it's planned. Custom prices survive re-planning, and extras count against the budget in the planner.
- **Saved → Today:** "Add to today's plan" appends the stop, confirms in place, and offers "View today's plan". Long-press a saved post for the same actions.
- **Moving through the day:** on a stop, "I'm here" makes it the current stop (earlier stops become done); "Done here" finishes it and makes the next one current. The timeline rail, map route and pins follow. Long-press a timeline row for the same actions. When every stop is done, Today shows a completion card.
- **New day:** a plan belongs to one date. On the first launch of a new day the old plan is filed under Recent plans and Today starts empty with the default budget.
- **Persistence:** saved posts, today's plan, profile preferences and recent plans are written to `plandit-store.json` in the App Group container (Application Support when unsigned). Launch with `-resetData` to go back to the sample data.

## Mocked or not built yet

- **Data:** `SampleData` seeds the first launch. Stats on Profile are still mock values.
- **Extraction:** TikTok links use the authenticated Django evidence endpoint when production
  configuration is present, then search MapKit for matching places. Instagram still depends on
  shared text or manually attached media; broader provider support is not built.
- **Planner:** The + planner orders stops by least travel (every order up to 7 stops, a fast search above that), keeps visits inside closing times read from `hours` ("Open until 9 PM"), and stays on budget including subway fares. Nightlife waits for 8 PM (or is left out if the day ends earlier), and "Free until" caps the day. It doesn't know other opening times yet, and its travel times are still the straight-line estimate (the Getting there sheet uses Apple Maps). It never picks driving by itself. The long-press "Add to today's plan" still just appends.
- **Transit:** MapKit has no transit geometry, so transit legs are drawn as straight dotted lines. Walking legs use real MapKit walking routes.
- **Dark mode:** Provisional dark tokens are documented in `docs/features/dark-mode/`. The canonical
  style guide remains unchanged until the design owners approve those tokens.
- **Profile:** Default budget, home base and getting around are editable and persisted. Notifications and recent-plan rows open placeholder screens.
- **Location:** Permission is requested only when the user taps the locate button. Camera bounds keep the map within Manhattan.
