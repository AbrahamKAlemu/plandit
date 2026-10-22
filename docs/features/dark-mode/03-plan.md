# Dark mode implementation plan

## Slice 1: Shared appearance contract and proof

**Outcome:** A stable System/Light/Dark contract parses persisted values safely and is available to
both targets.

**Owned files:** shared appearance source, project test configuration, focused tests.

**Dependencies:** Dossier approval.

**Safe landing:** No visible UI changes until the root consumes the preference.

## Slice 2: Adaptive design system and app-wide application

**Outcome:** The app root, MapKit, shared colors, logos, and fixed-purpose component colors respond
correctly to the selected mode.

**Owned files:** app entry point, project configuration, colors, buttons/components, map pins or
routes if visual verification finds a contrast defect, share-extension root.

**Dependencies:** Slice 1.

**Integration owner:** Main implementation.

**Safe landing:** System remains the default; explicit Light reproduces the existing presentation.

## Slice 3: Profile settings experience

**Outcome:** Profile -> Settings -> Appearance provides accessible System/Light/Dark selection and
updates the app immediately without losing navigation state.

**Owned files:** Profile feature views and any focused settings view tests.

**Dependencies:** Slices 1 and 2.

**Safe landing:** Existing Profile content remains intact; only the Settings placeholder becomes
functional.

## Slice 4: Integrated validation and review

**Outcome:** The feature is proven in all three modes, reviewed independently, judged by relevant
personas, and ready for a PR.

**Dependencies:** Slices 1-3.

## Verification table

| Requirement | Acceptance/failure case | Command/observation | Owner | Evidence/status |
|---|---|---|---|---|
| DM-1 | Profile -> Settings -> Appearance displays System, Light, Dark and one selected value. | Simulator interaction and UI test. | Builder | Pass: `AppearanceFlowTests` traverses the complete flow. |
| DM-2 | Changing each value updates visible sheets and map without restart or navigation reset. | Changed-user-flow simulator walk. | Builder + independent reviewer | Pass: UI test proves Light -> Dark immediate state change; final screenshots prove the effective scheme. |
| DM-3 | Selection survives termination/relaunch; invalid stored value opens in System. | Focused unit test plus simulator relaunch. | Builder | Pass: four unit tests and relaunch UI assertion. |
| DM-4 | Today, Saved, Profile, details, persistent sheet, and map use the effective appearance. | Light/dark screenshot matrix, including a dense Manhattan area with street, neighborhood, park, water, and available transit labels. | Independent completion reviewer | Pass: final Today, route-map, and saved-map evidence; normal MapKit label emphasis. |
| DM-5 | Share extension applies the stored preference when launched and a theme change does not interrupt saving a link. | Build plus extension inspection or simulator share flow where signing permits. | Builder | Pass with runtime limit: signed simulator build succeeds; app and extension contain the same App Group entitlement and extension root applies `AppearanceMode.saved`. The system share sheet was not automated. |
| DM-6 | Text, buttons, cards, pins, routes, native map labels, and logos remain legible with no color-only status. | Contrast measurements for app tokens plus light/dark changed-flow review. | Independent reviewer | Pass: selected state is 5.0:1, route state varies width/opacity and color, final code review found no issues, and Grace approved the revised evidence. |
| DM-7 | Fresh install/default storage follows the simulator's system appearance. | Unit test and system-theme simulator observation. | Builder | Pass: System maps to no override; forced-light plist values were removed. |
| DM-8 | Appearance rows have labels and selected state available to VoiceOver. | Accessibility inspector/code review. | Independent reviewer | Pass: explicit labels, values, selected traits, and UI-test selection queries. |

The integrated changed-user-flow walk starts with a saved post, opens its mapped place, adds it to
the nearby day plan, and confirms that address, route, timing, price, and next action remain easy to
scan in dark mode.

## Quality checks

- Follow the test-first loop for parsing/default behavior.
- Regenerate the Xcode project after target or file changes.
- Run the smallest focused tests, then build the complete app and extension.
- Exercise System, Light, and Dark on the simulator.
- Run relevant persona review; `must_fix` blocks completion.
- Run independent code review, completion review, and a final changed-user-flow walk.

## Rollout and rollback

No migration or backend rollout is required. Reverting the feature restores the prior forced-light
configuration. Persisted unknown values already fall back to System.

## Human approval

Status: **Approved by the user on October 14, 2026. Implementation and verification complete.**
