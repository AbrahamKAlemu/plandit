# Brief review history

## Persona review round 1

| Persona | Verdict | Score | Blocking finding | Disposition |
|---|---|---:|---|---|
| Sofia | Approve with conditions | 6/10 | Prove a fast happy path and make the result immediately useful with address/travel and Add to Plan. | Accepted in SPE-14 and SPE-15. |
| Marcus | Reject | 3/10 | Add no-saves instant plan generation with time, distance, hours, and dietary constraints; require sub-30-second flow. | Speed/actionability accepted in SPE-14/SPE-15. No-saves recommendation is a separate product surface and requires owner scope decision. |
| Grace | Approve with conditions | 5/10 | Show true cost/transit usefulness and guarantee no-paywall/manual outage behavior. | Transparent known/unknown cost and free/manual fallback accepted in SPE-15/SPE-17. Full day totals and exact transit belong to planning and require a separate brief. |
| Amara | Reject | 4/10 | Add browser-shareable group plan with time, meeting point, stops, and per-person cost. | Requires a separate planning/sharing feature and owner scope decision; not silently added to extraction. |
| Andre | Approve with conditions | 5/10 | Add save-age/recent density filtering and reliable closure/expiry context. | Accepted in SPE-15/SPE-16. |

## Scope-expansion blockers

Marcus and Amara identified real Plandit product needs, but their requested fixes are not extraction
or density details:

- a no-saves recommendation path for a user with no social backlog;
- full time/distance/hours/dietary plan generation;
- meeting-point and per-person group budgeting;
- browser-viewable sharing for friends without accounts.

Adding them here would combine multiple features, backend surfaces, and verification programs while
contradicting the agreed personal-saves-first scope. Product-owner direction is required:

1. Keep this dossier focused and commission separate briefs before making broader planning/group
   claims; or
2. Expand this initiative into a multi-feature program and restart architecture/slicing accordingly.

## Product-owner scope decision

The owner selected the focused option: keep this dossier limited to saved-place extraction and
personal density, and handle no-saves planning and browser group sharing as separate future Feature
Forge briefs. The focused Sofia/Grace/Andre findings were added as SPE-14 through SPE-17. A second
persona round must judge the amended brief against that explicit boundary.

## Backend decision

After a repository audit, the owner selected a Django modular monolith with PostgreSQL deployed on
Railway. Supabase is excluded from this feature to avoid splitting authentication, database policy,
migrations, and operational ownership before accounts or cross-device sync are in scope. SwiftData
remains the local user-data authority; Django owns the resolution API, provider secrets, redacted
operations data, and admin tooling.

User approval: "Perfect lets fo with Django + PostgreSQL"

## Persona review round 2

| Persona | Verdict | Score | Blocking finding | Disposition |
|---|---|---:|---|---|
| Sofia | Approve | 9/10 | None | Candidate cards and confirmed details already support neighborhood/travel context and Add to Today; visual prominence remains a build usability check. |
| Marcus | Approve | 8/10 | None | Origin/mode clarity incorporated into SPE-15; location permission must not block local saved-place access. |
| Grace | Approve with conditions | 6/10 | Price level alone was permitted instead of an actionable dollar amount/range and basis. | Accepted in amended SPE-15, data contract, fixtures, Slice 3, and verification. Targeted re-review pending. |
| Amara | Approve | 9/10 | None | Confidence/unknown-label comprehension and Add to Today prominence remain build usability checks. |
| Andre | Approve with conditions | 6/10 | Operational fields lacked visible last-checked and testable stale-refresh behavior. | Accepted as SPE-18 and added to data contract, flow, failures, Slice 3, fixtures, and verification. Targeted re-review pending. |

Grace and Andre must re-evaluate the amended requirements. Their prior `must_fix` findings remain
blocking until both return with no unresolved `must_fix`.
