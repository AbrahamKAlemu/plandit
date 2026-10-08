# Modular dossier templates

Use stable requirement IDs and relative Markdown links. Main docs may include
leaves with `<!-- forge-include: parts/brief/context.md -->`. Paths are relative
to their containing source, stay inside the dossier and cannot cycle. Review
siblings named `<document-stem>_reviews.md` compose after their document.

## Brief

Problem/user/context; scope and non-goals; solution outline; requirements and
failure cases; applicable UX; analytics/logging decision; rollout/flags decision;
open and resolved questions with rationale; selected PM findings and dispositions.
No mandatory separate Success Metrics section. Product metrics are optional.

## Architecture

Summary; existing structure; reconnaissance leaf; affected components; data/state
contracts; flows; meaningful alternatives leaf and rationale; failure modes;
security/privacy; links to Plan verification and brief questions; selected findings.

## Plan

Ordered coherent slices with outcome, scope, dependencies, integration owner and
safe landing; workstream contracts; single verification table:

| Requirement | Acceptance/failure case | Command/observation | Owner | Evidence/status |
|---|---|---|---|---|

Testing checkpoint findings/dispositions; human dossier approval; rollout and
final verification actions. Tasks reference rows instead of repeating requirements.

## Progress

Summary; attention needed; phase status; tasks/evidence; decisions/events.
Link every dossier document. Use explicit empty states and accurate approval records.
