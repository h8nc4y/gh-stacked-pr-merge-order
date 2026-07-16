---
name: gh-stacked-pr-merge-order
description: >-
  Merge stacked pull requests (chained PRs whose base is the previous PR's
  head branch) with the gh CLI without GitHub auto-closing the stack. Use on
  symptoms like: a child PR auto-closed when its base branch was deleted,
  "Cannot change the base branch of a closed pull request", "gh pr reopen"
  failing on an auto-closed PR, "gh pr merge --delete-branch" closing
  descendant PRs, retargeting children with "gh pr edit --base", a silent
  merge failure on a branch-protected repo followed by branch deletion
  auto-closing the PR, or a stacked docs PR polluted with feature commits.
  Covers the safe merge order (retarget before deleting base branches), a
  retarget-first bulk landing alternative, MERGED-state confirmation before
  branch deletion, supersedes-PR recovery, and cherry-pick stack splitting.
---

# gh Stacked PR Merge Order

Procedure for landing a stack of pull requests — #A ← #B ← #C, where each
child PR's base is the previous PR's head branch — with the GitHub CLI,
without GitHub auto-closing part of the stack. The core hazard: deleting a
base branch through the gh CLI or API can close every descendant PR without
retargeting it, and a PR closed that way can be neither retargeted nor
reopened. Prevention is everything.

## When To Use

- You merged the bottom PR of a stack with `gh pr merge --delete-branch`
  and the child PR closed itself the moment the branch vanished.
- `gh pr edit <n> --base <default>` fails with `Cannot change the base
  branch of a closed pull request`.
- `gh pr reopen <n>` fails on a PR that GitHub closed automatically (for
  example `Could not open the pull request`).
- You are about to integrate a chain of PRs with the gh CLI and want the
  order that avoids all of the above.
- On a branch-protected repository, a merge "ran", but after a branch
  deletion the PR turned out closed instead of merged.
- A stacked documentation PR turns out to contain unrelated feature
  commits.

## Why It Happens

How the base branch dies determines what happens to the PRs based on it
(observed as of July 2026 — GitHub may change this behavior):

- Deleting the branch from the **web UI** (the post-merge "Delete branch"
  button) retargets descendant PRs onto the repository's default branch
  automatically.
- Deleting the branch through the **gh CLI or the API** — including `gh pr
  merge --delete-branch` — has been observed to close descendant PRs
  without retargeting them.

Once a PR is auto-closed this way, it is unrecoverable in place
(field-tested):

- `gh pr edit <n> --base <default>` is refused: `Cannot change the base
  branch of a closed pull request`.
- `gh pr reopen <n>` is refused as well.

So the discipline is preventive: never let a branch disappear while any
open PR still uses it as base.

## The Safe Merge Order

For a stack #A ← #B ← #C (#A's base is the default branch, #B's base is
#A's head branch, #C's base is #B's head branch). Get `<default>` from
`gh repo view <owner>/<name> --json defaultBranchRef -q
.defaultBranchRef.name` instead of assuming `main`.

1. Merge the bottom PR **without** `--delete-branch`:

   ```bash
   gh pr merge <A> --repo <owner>/<name> --merge
   ```

   Use your repository's merge mode (`--merge`, `--squash`, or
   `--rebase`); what matters here is the absent `--delete-branch`.

2. Confirm the merge actually happened before mutating anything else:

   ```bash
   gh pr view <A> --repo <owner>/<name> --json state,mergedAt
   ```

   Require `"state": "MERGED"`. Do not skip this on branch-protected
   repositories (see the timing trap below).

3. Retarget the next PR onto the default branch:

   ```bash
   gh pr edit <B> --repo <owner>/<name> --base <default>
   ```

4. Check mergeability after the retarget:

   ```bash
   gh pr view <B> --repo <owner>/<name> --json mergeable,mergeStateStatus
   ```

   If `mergeable` is `CONFLICTING`, resolve on the head branch locally:

   ```bash
   git fetch origin
   git switch <B-head-branch>
   git merge origin/<default>     # resolve conflicts, then commit
   git push origin <B-head-branch>
   ```

5. Merge #B (again without `--delete-branch`), confirm `MERGED`, and
   repeat retarget → verify → merge for #C and any further descendants.

6. Delete head branches only after **every** PR in the stack reports
   `MERGED`, and check each branch for remaining dependents first:

   ```bash
   gh pr list --repo <owner>/<name> --base <branch> --state open   # must be empty
   git push origin --delete <A-head> <B-head> <C-head>
   ```

Rules of thumb:

- `--delete-branch` is banned inside a stack. It is fine on an isolated,
  single PR whose head branch no other PR uses as base.
- One mutation at a time: after every merge, verify state before the next
  retarget or deletion.

## Alternative: Retarget-First Bulk Landing

A field-tested variant that lands the whole stack with a single merge:

1. Retarget every open PR in the stack onto the default branch first,
   bottom-up: `gh pr edit <n> --repo <owner>/<name> --base <default>`.
2. Merge only the tip PR (the one whose head branch contains all commits
   in the stack) — without `--delete-branch`.
3. GitHub detects that the other PRs' head commits are now contained in
   their base and marks those PRs `MERGED` automatically (observed as of
   July 2026).

When to prefer it: a purely additive stack (each PR's head strictly
contains its ancestors' commits) where one CI run and one merge beat N of
them.

Caveats:

- Retargeting changes each intermediate PR's visible diff to the
  cumulative diff against the default branch; reviewers subscribed to
  those PRs see the shape change.
- The automatic `MERGED` detection requires the stack's commits to become
  ancestors of the default branch, so merge the tip with a merge commit
  (`--merge`). After `--squash` or `--rebase` the original commits never
  become ancestors, so do not expect the contained PRs to be detected as
  merged — derived from git semantics, not exercised (untested).
- Interaction with merge queues: untested.

## If A PR Was Auto-Closed

First identify what was lost: a PR reporting `"state": "CLOSED"` with
`"mergedAt": null` was closed without its content merging. Reopening is
not possible; supersede instead. The head branch still exists — only its
base branch was deleted — so:

```bash
gh pr create --repo <owner>/<name> --head <same-head-branch> --base <default> \
  --title "<original title>" \
  --body "Supersedes #<closed-number>.

<original body>"
```

- Write `Supersedes #<closed-number>` in the body so the history stays
  traceable from the closed PR's timeline.
- Review approvals do not carry over; re-request them if the repository
  requires reviews.
- Land the new PR with the safe order above.

## Branch-Protection Timing Trap

On a repository with branch protection (required status checks), a merge
attempted before the checks complete does not happen — and in scripted or
loop contexts that refusal is easy to miss. The dangerous sequence,
observed in the field: merge attempt (refused, unnoticed) → branch
deletion → the still-open PR is auto-closed.

The rule: **merge → confirm `MERGED` → only then delete**, every time,
including inside loops:

```bash
gh pr merge <n> --repo <owner>/<name> --merge
gh pr view <n> --repo <owner>/<name> --json state,mergedAt   # require MERGED
# delete the head branch only after this, and only once the stack is fully landed
```

On protected repositories, either wait for checks with bounded polling
(`gh pr checks <n> --repo <owner>/<name> --watch=false`, repeated with a
capped attempt count), or queue the merge with `gh pr merge --auto`, which
merges only after requirements are met. Never combine `--auto` with
`--delete-branch` inside a stack — the deferred merge would delete a base
branch out from under the descendants at an unattended moment.

If the trap already fired, the PR is closed with its content unmerged:
recover with a supersedes PR exactly as above.

## Splitting Mixed Stacks

When a stacked documentation or refactor PR turns out to contain unrelated
feature commits (or the reverse), do not merge the mix and do not rewrite
the stack in place. Split it (field-tested):

1. Branch fresh from the default branch.
2. `git cherry-pick` only the commits that belong.
3. Open a new PR from that branch.
4. Close the old PR with a comment noting `Superseded by #<new-number>`.

The stray commits stay on the old head branch, unmerged, until their own
properly-scoped PR picks them up.

## State-Snapshot Document Conflicts

Documents that snapshot mutable state — handoff notes, task backlogs,
status boards — tend to be edited in every layer of a stack, so they
conflict at almost every retarget or merge step.

- Resolve mechanically by taking the newer side (the descendant's
  version).
- Do not hand-craft an intermediate state mid-stack. Land the stack, then
  write one final docs-only PR that syncs the snapshot document to
  post-integration reality.

## Do Not / Stop Conditions

- Never delete a branch while `gh pr list --base <branch> --state open`
  reports any PR.
- Never use `--delete-branch` — including with `--auto` — inside a stack.
- Do not retry `gh pr edit --base` or `gh pr reopen` against an
  auto-closed PR expecting a different outcome; go straight to the
  supersedes recovery.
- Do not resolve state-snapshot conflicts by inventing an intermediate
  state mid-stack; take the newer side and sync at the end.
- If the same failure class does not improve after three attempts, stop
  and report. Cost, secret, and credential stop conditions always take
  precedence.

## Completion Checklist

- Every PR in the stack reports `MERGED`:
  `gh pr view <n> --repo <owner>/<name> --json state,mergedAt`.
- No open PR still bases on any branch about to be deleted:
  `gh pr list --repo <owner>/<name> --base <branch> --state open` is
  empty.
- Head branches deleted only after the two checks above, in one final
  sweep.
- Every superseded or auto-closed PR has a successor PR whose body links
  it (`Supersedes #<n>`).
- Snapshot documents synced by a final docs-only PR if they conflicted
  during the stack.

## Portability

Every command above is `git` or `gh` and runs unchanged in POSIX shells
and PowerShell. The multi-line `--body` example uses POSIX line
continuation; in PowerShell, pass `--body-file <file>` instead of
embedding newlines.

## Reporting

- Start reports with a timestamp (date and time, in a stated timezone).
- Include: the PRs landed in order with their final states, conflicts hit
  and how they were resolved, branches deleted with the pre-deletion
  evidence (`MERGED` states and the empty dependent-PR listing), any
  supersedes recoveries performed, and open unknowns.
- Do not assert platform behavior you did not observe; mark it
  unverified.

## Provenance

Distilled from repeated real agent operations landing multiple stacked-PR
sets across multiple repositories, including live incident recoveries —
every rule above traces to an observed failure or a verified recovery.
GitHub-side behaviors (CLI/API deletion closing descendants without
retargeting, web-UI deletion retargeting them, automatic MERGED detection
after a bulk landing) are observations as of July 2026, not documented
contracts; re-verify before depending on them, and expect them to change
without notice. Items marked untested — the bulk-landing behavior under
squash/rebase modes and any merge-queue interaction — have not been
exercised.
