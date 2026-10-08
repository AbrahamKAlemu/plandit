---
name: whetstone
description: A short spec, build and independent review route for small understood changes.
user-invocable: true
---

# Whetstone

Use for small understood behavior changes; do trivial edits directly and escalate uncertain or consequential work to Feature Forge. Read project conventions, establish an isolated branch/worktree and preserve unrelated work. Write one compact spec with problem, behavior, scope, approach, questions, verification table, rollout and review owners. Obtain required human approval and select useful pre-build review. Implement with focused tests, integration and changed-flow checks. Before PR, an independent reviewer checks integrated code/behavior against the spec with pass/fail/unverified evidence; resolve required gaps. Follow human merge/deploy gates, release verification and cleanup. Keep concise progress; do not restart the full docs pipeline.
