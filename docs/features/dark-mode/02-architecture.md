# Dark mode architecture

## Summary

Appearance becomes a small shared domain contract rather than view-local state. A shared
`AppearanceMode` enum owns parsing, display names, storage key, and optional SwiftUI
`ColorScheme`. The app root reads the stored raw value and applies `preferredColorScheme`, while
Settings writes the same value. The share extension reads the same App Group preference when it
constructs its SwiftUI root.

Semantic colors become adaptive. Fixed-purpose foreground colors are separate so components do not
accidentally invert labels that must remain black on emerald.

## Existing structure and reconnaissance

- `ios/Plandit/App/PlanditApp.swift` owns the app root but has no appearance state.
- `ios/Plandit/Features/Profile/ProfileSheet.swift` routes Settings to a placeholder.
- `ios/Shared/DesignSystem/Colors.swift` defines light-only code constants.
- `ios/Shared/Sharing/ShareInbox.swift` already provides App Group defaults with a standard-defaults
  fallback.
- `ios/project.yml` forces both targets to `UIUserInterfaceStyle: Light`.
- MapKit is embedded in the SwiftUI hierarchy, so it follows the effective color scheme when the
  forced-light setting is removed.
- Brand assets include light and dark lockups, but Profile always renders `lockupLight`.
- Several components use semantic `ink` in fixed-color contexts; those need explicit
  `onEmerald`/inverse treatment.

## Affected components

| Component | Change |
|---|---|
| Shared appearance contract | Add `AppearanceMode` and shared storage helpers. |
| App root | Bind shared preference and apply the effective color scheme. |
| Project configuration | Remove forced-light appearance from the app and share extension. |
| Profile navigation | Replace the Settings placeholder with a Settings screen and Appearance destination. |
| Shared colors | Add adaptive canvas, surface, text, muted, border, tint, and error values. |
| Components | Audit fixed foreground/background pairs and route/pin contrast. |
| Brand artwork | Select light or dark lockup using the active color scheme. |
| Share extension | Apply the shared preference to its SwiftUI root. |
| Tests | Add focused appearance parsing/default tests and a test target if required. |

## Data and state contract

```swift
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "plandit.appearanceMode"
    static func resolve(_ rawValue: String?) -> AppearanceMode
    var colorScheme: ColorScheme?
}
```

The persisted representation is the enum raw value. `system` maps to `nil`,
`light` maps to `.light`, and `dark` maps to `.dark`.

Storage uses `AppGroup.defaults`, which already falls back to `.standard` when the entitlement is
unavailable. The app root and Settings use the same key and store so updates are immediate and
persistent. Unknown values resolve to System.

## Theme flow

1. The app launches and reads `plandit.appearanceMode`.
2. `AppearanceMode.resolve` converts the value or falls back to System.
3. `PlanditApp` applies the mode's optional color scheme to `RootView`.
4. SwiftUI recomputes adaptive colors and MapKit follows the effective interface style.
5. The user opens Profile -> Settings -> Appearance and selects a row.
6. The raw value is written to shared defaults; the app updates immediately.
7. A later share-extension launch reads the same value and applies it to `ShareView`.

## Provisional dark tokens

These values are feature-local pending style-guide approval:

| Semantic role | Light | Dark |
|---|---|---|
| Canvas | `#F7F8FA` | `#0E0F12` |
| Surface | `#FFFFFF` | `#17191D` |
| Primary text/structure | `#0E0F12` | `#F7F8FA` |
| Muted text | `#5D626B` | `#AEB4BE` |
| Border | `#DDE2E8` | `#34383F` |
| Emerald tint | `#E4F5EC` | `#153D2B` |
| Error | `#C93434` | `#FF7474` |
| On emerald | `#0E0F12` | `#0E0F12` |

Emerald remains `#0FA968`. The design retains no gradients, glass, decorative red, or additional
brand colors.

## Failure modes and handling

- **Invalid preference:** resolve to System.
- **App Group unavailable:** existing fallback uses standard defaults, preserving local behavior.
- **Fixed-color contrast regression:** use explicit foreground tokens rather than adaptive `ink`.
- **Incorrect logo on dark surface:** choose the supplied dark lockup from the environment scheme.
- **Map overlays lose contrast:** validate pins and every leg state against both map styles and add
  outline treatment only where existing semantic colors are insufficient.
- **Theme switch resets navigation:** hold preference at the app root and avoid recreating store or
  router identity.

## Security and privacy

The feature stores one non-sensitive local string. It adds no network calls, credentials, user
tracking, or new trust boundary. App Group access remains limited to the existing app and share
extension entitlements.

## Alternatives considered

| Alternative | Decision |
|---|---|
| Keep light-only UI | Rejected; it ignores the requested experience and device preference. |
| Simple Dark Mode boolean | Rejected; it cannot distinguish System from an explicit Light override. |
| Separate hard-coded dark screens | Rejected; duplicates styling and will drift as screens evolve. |
| Asset-catalog colors | Not selected for this slice; code-defined adaptive tokens match the existing design-system pattern and minimize generated project churn. |
| Theme only sheets, not MapKit | Rejected by the selected whole-app scope. |

## Verification links

Acceptance and evidence are owned by the table in [03-plan.md](03-plan.md).
