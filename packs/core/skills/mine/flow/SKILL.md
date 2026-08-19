---
name: flow
description: Route a task to the right skill in this set. Use at the start of a session, when unsure which skill applies, or when a skill hands off to another.
---

# Flow

This set has a spine, a set of side loops, and breadth checks. Find where the work sits,
apply that skill, and stop — do not run the whole chain because it exists.

## The spine

```
idea → grill-with-docs → to-spec → to-tickets → implement → code-review
```

| You have | Apply |
|---|---|
| A vague idea, or a change you cannot yet describe precisely | `grill-with-docs` |
| A conversation where the deciding is done | `to-spec` |
| A spec or plan that needs slicing into buildable work | `to-tickets` |
| Tickets or a spec ready to build | `implement` |
| A diff about to land | `code-review` |

Most work does not need the whole spine. A one-file fix needs none of it.

## Side loops

| Situation | Apply |
|---|---|
| Something is broken, slow, or behaving unexpectedly | `diagnosing-bugs`, then `tdd` |
| Writing or changing behaviour | `tdd` |
| "How should this look / behave" cannot be settled by talking | `prototype` |
| A fact outside this repo is blocking a decision | `research` |
| Terminology is fuzzy, or `CONTEXT.md` / an ADR needs updating | `domain-modeling` |
| Deciding where a module boundary goes | `codebase-design` |
| Mid-merge or mid-rebase with conflicts | `resolving-merge-conflicts` |
| The session has outgrown itself | `handoff` |
| Writing a skill, `AGENTS.md`, or `CLAUDE.md` | `writing-for-agents` |

## Breadth checks

Reach for these when the work touches their area, not on every task:
`security-and-hardening`, `performance-optimization`, `api-and-interface-design`,
`ci-cd-and-automation`, `shipping-and-launch`, `deprecation-and-migration`.

## Standing rules

These hold across every skill in the set.

1. **Surface assumptions before acting.** State them, then proceed — do not silently
   resolve an ambiguity that changes the work.
2. **Stop when confused.** Name the specific inconsistency and ask. Do not guess and
   continue.
3. **Push back when an approach has a concrete problem.** Quantify it. Agreement that
   costs the user a rewrite is worse than disagreement.
4. **Stay in scope.** Do not refactor adjacent code, delete things you do not understand,
   or remove comments you cannot explain.
5. **Verify with evidence.** Passing tests, build output, real runtime data. "Looks right"
   is not a result.

## First run in a repo

`to-spec` and `to-tickets` need to know where issues live. If they report no
issue tracker configured, apply `setup-matt-pocock-skills` once for that repo.
