# Dark mode progress

## Summary

Dark mode is implemented on `feature/dark-mode`, based on `origin/ios-scaffold`. Profile Settings
now provides System, Light, and Dark choices; the preference persists, applies immediately to the
full app and MapKit, and is consumed by the share extension.

## Attention needed

- Dark tokens remain provisional and intentionally do not modify `docs/style_guide.md`.
- The share extension builds with matching App Group entitlements, but its system share-sheet flow
  was not automated in the simulator.
- Commit/PR/merge remain human shipping decisions.

## Phase status

| Phase | Status |
|---|---|
| Clarification | Complete |
| Brief | Approved |
| Architecture | Approved |
| Plan | Approved |
| Human approval | Complete |
| Build | Complete |
| Verification | Complete |
| Ship | Awaiting human decision |

## Decisions and events

- Selected System/Light/Dark rather than a boolean toggle.
- Selected whole-app theming including MapKit.
- Kept canonical style-guide changes out of scope.
- Created an isolated worktree and branch; dirty `main` files remain untouched.
- Completed persona review: all five personas approve with no remaining `must_fix`.
- Rejected adding live heat/freshness signals because dark mode must not become a discovery feature;
  clarified the non-goal and received Andre's scoped approval.
- Added focused unit and UI test targets to the generated Xcode project.
- Fixed pre-existing Swift 6/Xcode 16 build blockers required to run the feature locally.
- Added adaptive colors, fixed-purpose foreground colors, dark launch treatment, brighter native
  map labels, and route-state width/opacity differences.
- First independent review found a launch-screen flash and a weak persistence test; both were fixed.
- Final code re-review reported no significant issues.
- All five personas approve the implemented experience with no remaining `must_fix`.

## Evidence

- [Brief](01-brief.md)
- [Architecture](02-architecture.md)
- [Plan](03-plan.md)
- Unit tests: 4 passing.
- UI tests: 1 passing, including immediate Light -> Dark change and relaunch persistence.
- Signed simulator build: passing for the app and share extension.
- Visual evidence: `dark-mode-evidence/map-today-dark-final.png`,
  `map-saved-dark-final.png`, and `today-dark-final.png` in session artifacts.
