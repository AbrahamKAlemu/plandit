# Plandit (iOS)

SwiftUI scaffold for Plandit: turn saved TikToks and Reels into a real day plan in Manhattan.

The app copies Find My's layout. A full-screen Manhattan map sits behind a sheet that never closes. The tab bar lives inside that sheet. Each tab swaps both the sheet's content and the map's layers.

| Tab | Sheet | Map |
| --- | --- | --- |
| **Today** | The Plandit day: summary (time, budget, walking), directions to the next stop, and the stop-by-stop timeline. Tap a stop to open its details. | Numbered stops and the route. Walking legs are solid lines, transit legs are dotted. The active leg is emerald. |
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

Dev launch arguments (Scheme → Run → Arguments): `-startTab saved|profile` and `-startDetent peek|large`.

Appearance follows the device by default. Open **Profile → Settings → Appearance** to choose
System, Light, or Dark; the preference also applies to the share extension.

### Testing Share → Plandit

You need a signed build with the App Group capability. On a device, or in a simulator with Safari: open a TikTok or Instagram link, tap Share, then **Plandit**, then **Save to Plandit**. When you switch back to Plandit, it reads the shared inbox and the post appears in Saved as "Mapping".

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
  Services/         PlanditStore (state), RouteService (MapKit walking paths), PlaceExtractor
PlanditShare/       Share extension: accepts a URL or text containing a link, queues it in the App Group
Shared/             Code and assets compiled into both targets
  DesignSystem/     Color tokens, Manrope type scale, spacing, Lucide Icon, BrandArt, button styles
  Sharing/          ShareInbox (App Group handoff), link parsing, SourcePlatform
  Fonts/            Manrope 400–800 (OFL)
  SharedAssets.xcassets   Brand/ (official logo SVGs) and Icons/ (Lucide)
Design/Logo/        The full logo package, copied unchanged from the design team
```

## Design system

Everything follows the *Plandit Style Guide* (October 2026):

- **Color:** `Shared/DesignSystem/Colors.swift`. Emerald marks the single most important action. Ink is for structure. Red is used only for errors and unavailable states. No gradients, no glass.
- **Type:** Manrope via `Font.pageHeading`, `.cardHeading`, `.bodyText`, `.label`, `.metadata`, and so on (the mobile scale from the guide).
- **Icons:** Lucide only, through `Icon(.clock)`. To add one, put the SVG from lucide.dev into `Shared/SharedAssets.xcassets/Icons` with stroke width 1.75 and template rendering. Don't use SF Symbols in product UI.
- **Logo:** `BrandArt.mark`, `.lockupLight`, and the rest load the official SVGs. Don't recolor or rebuild them. Use the favicon export below 24pt, and no lockup narrower than 120pt.
- **Buttons:** `.buttonStyle(.primary)` (emerald fill, ink label) and `.secondary` (ink outline).

Asset sources:
- Logos come from `Design/Logo`.
- The app icon is `mark-square` and `mark-on-dark` with the background made full-bleed, because iOS applies its own corner mask.
- Lucide icons are ISC licensed and came from `lucide-static@0.469.0`.
- Manrope is OFL licensed. The static weights were instanced from the Google Fonts variable font.

## Flows worth knowing

- **Share → Plandit → app:** when the app comes back to the foreground it drains the share inbox, switches to Saved, and opens the new post so you can watch it get mapped. Pasting a link does the same.
- **Saved → Today:** "Add to today's plan" appends the stop, confirms in place, and offers "View today's plan". Long-press a saved post for the same actions.
- **Moving through the day:** on a stop, "I'm here" makes it the current stop (earlier stops become done); "Done here" finishes it and makes the next one current. The timeline rail, map route and pins follow. Long-press a timeline row for the same actions. When every stop is done, Today shows a completion card.
- **New day:** a plan belongs to one date. On the first launch of a new day the old plan is filed under Recent plans and Today starts empty with the default budget.
- **Persistence:** saved posts, today's plan, profile preferences and recent plans are written to `plandit-store.json` in the App Group container (Application Support when unsigned). Launch with `-resetData` to go back to the sample data.

## Mocked or not built yet

- **Data:** `SampleData` seeds the first launch. Stats on Profile are still mock values.
- **Extraction:** `StubPlaceExtractor` fetches real TikTok oEmbed metadata (caption, author, thumbnail), then assigns a random sample place. Replace it with the backend (caption, transcript and on-screen text → place).
- **Planner:** "Add to today's plan" appends the stop with an estimated travel leg. It does not re-optimize order, time or budget.
- **Transit:** MapKit has no transit geometry, so transit legs are drawn as straight dotted lines. Walking legs use real MapKit walking routes.
- **Dark mode:** Provisional dark tokens are documented in `docs/features/dark-mode/`. The canonical
  style guide remains unchanged until the design owners approve those tokens.
- **Profile:** Default budget, home base and getting around are editable and persisted. Notifications and recent-plan rows open placeholder screens.
- **Location:** Permission is requested only when the user taps the locate button. Camera bounds keep the map within Manhattan.
