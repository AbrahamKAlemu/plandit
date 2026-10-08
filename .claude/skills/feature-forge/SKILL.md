---
name: feature-forge
description: Guide substantial features through brief, architecture, plan, coherent slices, independent completion review and human shipping gates.
user-invocable: true
---

# Feature Forge

Read the consuming project's instructions. Respect authorization, branch and
shipping conventions; use actual project verification commands. Fetch before
choosing a base. Establish an isolated branch/worktree and preserve unrelated work.
Clarify premise, users, alternatives including doing nothing, and open decisions.

## Document and approve

Create `docs/features/<feature>/` with optional clarification, numbered brief,
architecture, plan and progress Markdown files. Use sibling brief/architecture/
plan skills and [templates](references/templates.md). Split by readership with
`<!-- forge-include: parts/brief/context.md -->`; compose all leaves and review
history for the human. Give builders relevant authoritative sections, allowing
necessary further investigation.

Brief preserves context, solution outline, requirements, scope, analytics/logging,
rollout/flags and question history. Select optional PM review by need.
Architecture preserves reconnaissance, affected components, flows, failure modes
and meaningful alternatives. Choose architecture/security perspectives by need.
Skip wireframes. Plan owns the single verification table mapping requirements to
measurable acceptance, failure variants, proof, owner and evidence. Select an
optional independent Plan testing perspective when useful. The writer owns consistency/readability;
do not add automatic clarity-reader or Plan code-lead/EM/design chains.

Integrate findings into source bodies and record dispositions and rationale.
Present one comprehensive dossier for consolidated human approval before build.
Use Markdown, optional HTML via `scripts/build_feature_docs.py <feature-folder>`
(requires Pandoc), or LAHE following its installed skill and session contract.
Record explicit approval and unresolved questions; silence is not approval.

## Build, independently verify and ship

Use [contracts and slices](references/contracts-and-slices.md). Choose safely
landable outcomes with dependencies, shared-interface and integration ownership.
Keep coupled behavior together and the app working after each landing. Do not
repeat the docs pipeline per slice. Choose delegation, model, grouping, reuse
and reviewer selection judiciously, within host capabilities and user policy.
No fixed cap, prescribed pool or automatic roster.

Run targeted tests while building and seam tests after integrating workstreams.
Follow the [test-first build loop](references/build-loop.md) for behavioral changes.
Run independent code review, completion review and one final independent changed-user-flow walk before PR.
Playwright or another browser tool is an option for browser workflows.

Before PR, assign an independent reviewer/evaluator to check integrated code and
observed behavior against requirements and acceptance. Orchestrator self-review
cannot substitute. An existing independent reviewer may own this scope explicitly.
Use [review perspectives](references/reviewers.md): one owner per check, no
duplicate parent/lead roster. Report pass/fail/unverified with revision, actual
evidence and limits. Resolve required gaps and recheck affected criteria.

Prepare coherent PRs with proof, dependencies and rollout. Await required human
merge/deployment approval. Verify release, update durable docs/lessons and clean
only owned temporary resources with authorization. Keep progress current with
summary, attention needed, phases, tasks/evidence and decisions/events.
