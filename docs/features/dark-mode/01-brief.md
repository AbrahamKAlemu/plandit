# Dark mode feature brief

## Problem, user, and context

Plandit's iOS scaffold is locked to light appearance even when a student's device uses dark mode.
The emerald-and-black identity can support a dark presentation, but the current color constants,
logo choice, MapKit presentation, and placeholder Settings screen do not provide a coherent or
persistent appearance preference.

This feature is for students who use Plandit in low-light environments or prefer dark interfaces.
It must preserve the product's practical hierarchy: the plan, price, distance, and next action stay
more prominent than decoration.

## Solution outline

Add an Appearance screen under Profile -> Settings with three choices:

- System
- Light
- Dark

The selection applies immediately to the full app, including MapKit, persists between launches,
and is shared with the share extension. Semantic color tokens gain provisional dark values while
fixed-purpose colors keep explicit foreground contracts, such as black text on emerald buttons.

## Requirements

| ID | Requirement |
|---|---|
| DM-1 | Profile -> Settings exposes an Appearance destination with System, Light, and Dark choices. |
| DM-2 | The selected appearance applies immediately without restarting the app. |
| DM-3 | The preference persists across launches and an unknown stored value safely falls back to System. |
| DM-4 | The selected appearance covers all primary app surfaces and the MapKit map. |
| DM-5 | The share extension uses the same appearance preference when the App Group is available. |
| DM-6 | Text, controls, cards, routes, pins, and logos remain legible in both light and dark appearances without relying on color alone. |
| DM-7 | Existing users default to System and may explicitly override it with Light or Dark. |
| DM-8 | Appearance controls expose clear accessibility labels and selected state. |

## Failure cases

- A missing or invalid saved value must resolve to System rather than preventing launch.
- If App Group storage is unavailable in an unsigned simulator build, the main app must still
  persist the preference in its standard defaults without crashing.
- Switching themes must not dismiss the current tab, navigation destination, or sheet state.
- Dark mode must not make emerald buttons use white text or create white-on-white inverse controls.
- The map and its overlays must remain distinguishable in both appearances.

## Scope

### Included

- Persistent System/Light/Dark preference.
- Real Settings and Appearance screens.
- Adaptive semantic color tokens and fixed-purpose foreground tokens.
- Adaptive logo selection.
- Main app, MapKit, and share-extension appearance.
- Focused tests for appearance parsing and fallback behavior.
- Light and dark simulator evidence for the main tabs and Appearance screen.

### Not included

- Editing `docs/style_guide.md`; dark tokens remain provisional pending separate owner approval.
- Additional brand colors, gradients, or a redesigned visual system.
- Automatic scheduling based on time of day beyond the iOS System option.
- Changing planning, extraction, persistence, or routing functionality.
- Adding live heat, popularity, freshness, line, or guest-list signals. Dark mode presents existing
  planning information; it does not turn the map into a discovery feed.

## Analytics and logging

No analytics are added. This repository has no analytics system, and appearance preference is local
UI state rather than a product event that justifies introducing one.

Invalid stored values use the repository's safe local fallback behavior. No sensitive data is
collected or transmitted.

## Rollout

No feature flag is needed for this scaffold. The default is System, so the app follows the device
unless the user selects an override. The change lands as one reversible feature branch based on
`origin/ios-scaffold`.

## Decisions and question history

| Question | Decision | Rationale |
|---|---|---|
| Two-state switch or three-state choice? | System/Light/Dark selector. | Respects device preference while allowing an explicit override. |
| Theme the map? | Yes, theme the whole app including MapKit. | A light map behind dark sheets would feel unfinished and create excessive contrast. |
| Update the canonical style guide? | No. Keep tokens in this dossier. | The user selected feature-doc-only handling; owner sign-off remains required for the style guide. |
| Share extension behavior? | Use the shared preference when available. | It is a user-facing Plandit surface and should not contradict the selected mode. |

## Persona review

| Persona | Verdict | Disposition |
|---|---|---|
| Sofia | Approve, 8/10 | Added an integrated saved-post-to-plan dark-mode walkthrough to verification. |
| Marcus | Approve, 9/10 | Preserved System as the no-setup default and added no prompt or onboarding step. |
| Grace | Approve, 8/10 | Strengthened measurable contrast and dense transit-label/map verification. |
| Amara | Approve, 8/10 | Added a check that appearance changes do not interrupt the share flow. |
| Andre | Approve, 8/10 after scoped re-review | The first review requested live heat/freshness signals. That scope expansion was rejected because it conflicts with the planner-first guardrail. After the boundary and dense-map verification were clarified, Andre approved with no blockers. |

## Approval

Status: **Approved by the user on October 14, 2026.**
