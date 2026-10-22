# Live appearance toggle fix

## Problem

Selecting Light or Dark updates the selected row and persists the value, but the surrounding app
can remain in its previous effective color scheme until relaunch.

## Expected behavior

- Selecting Light immediately makes the current app hierarchy light.
- Selecting Dark immediately makes the current app hierarchy dark.
- System continues following the device appearance.
- The selected value persists across relaunch and remains shared with the extension.

## Scope and approach

Use one observable `AppearanceSettings` instance for the app hierarchy. Settings updates that
instance directly, the app root reads it directly, and the state owner persists every change to one
stable App Group `UserDefaults` instance. No visual redesign or preference migration is included.

## Verification

| Behavior | Proof |
|---|---|
| Light updates the effective scheme immediately | UI test checks selected Light and effective Light on the same screen. |
| Dark updates the effective scheme immediately | UI test checks selected Dark and effective Dark on the same screen. |
| Dark persists | UI test terminates and relaunches, then confirms Dark remains selected. |
| Existing parsing fallback remains valid | Existing `AppearanceModeTests` stay green. |

The user's bug report authorizes this corrective change. Independent review owns final confirmation.

## Result

Complete. The regression test now proves Light changes the effective scheme immediately, Dark
changes it back immediately inside the persistent sheet, and Dark remains selected after relaunch.
Independent review found no remaining issues.
