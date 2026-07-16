# Three-PR Stack Walkthrough — Every Command, Start To Finish

Synthetic example. `<owner>/<name>` is a placeholder; PR numbers `#101`,
`#102`, `#103` and branch names `step-1`, `step-2`, `step-3` are synthetic.
Nothing here refers to a real repository.

The stack:

| PR | Head branch | Base branch | Contains |
| --- | --- | --- | --- |
| #101 | `step-1` | `main` (default) | commits A |
| #102 | `step-2` | `step-1` | commits A + B |
| #103 | `step-3` | `step-2` | commits A + B + C |

Discover the default branch instead of assuming `main`:

```bash
gh repo view <owner>/<name> --json defaultBranchRef -q .defaultBranchRef.name
```

## Path 1 — Sequential Safe Order

### Land #101

```bash
gh pr merge 101 --repo <owner>/<name> --merge          # NO --delete-branch
gh pr view 101 --repo <owner>/<name> --json state,mergedAt
# require: "state": "MERGED"
```

### Retarget and land #102

```bash
gh pr edit 102 --repo <owner>/<name> --base main
gh pr view 102 --repo <owner>/<name> --json mergeable,mergeStateStatus
```

If `mergeable` is `CONFLICTING`, resolve on the head branch:

```bash
git fetch origin
git switch step-2
git merge origin/main        # resolve conflicts, then commit
git push origin step-2
```

Then merge, and confirm before moving on:

```bash
gh pr merge 102 --repo <owner>/<name> --merge          # still NO --delete-branch
gh pr view 102 --repo <owner>/<name> --json state,mergedAt
# require: "state": "MERGED"
```

### Retarget and land #103

```bash
gh pr edit 103 --repo <owner>/<name> --base main
gh pr view 103 --repo <owner>/<name> --json mergeable,mergeStateStatus
gh pr merge 103 --repo <owner>/<name> --merge
gh pr view 103 --repo <owner>/<name> --json state,mergedAt
# require: "state": "MERGED"
```

### Delete the head branches — one guarded sweep at the end

```bash
# Every branch must have zero open PRs using it — as base (dependents)
# and as head (a straggler PR that never reached MERGED):
gh pr list --repo <owner>/<name> --base step-1 --state open   # must be empty
gh pr list --repo <owner>/<name> --base step-2 --state open   # must be empty
gh pr list --repo <owner>/<name> --base step-3 --state open   # must be empty
gh pr list --repo <owner>/<name> --head step-1 --state open   # must be empty
gh pr list --repo <owner>/<name> --head step-2 --state open   # must be empty
gh pr list --repo <owner>/<name> --head step-3 --state open   # must be empty

git push origin --delete step-1 step-2 step-3
```

## Path 2 — Retarget-First Bulk Landing

Same stack, one merge. Works when the stack is purely additive (each head
strictly contains its ancestors' commits).

```bash
# 1. Retarget every open PR onto the default branch, bottom-up.
#    #101 already bases on main — no retarget needed for it.
gh pr edit 102 --repo <owner>/<name> --base main
gh pr edit 103 --repo <owner>/<name> --base main

# 2. Merge ONLY the tip, with a merge commit (--merge), NO --delete-branch:
gh pr merge 103 --repo <owner>/<name> --merge

# 3. GitHub marks the contained PRs MERGED automatically
#    (observed as of July 2026 — verify before relying on it):
gh pr view 101 --repo <owner>/<name> --json state,mergedAt
gh pr view 102 --repo <owner>/<name> --json state,mergedAt
gh pr view 103 --repo <owner>/<name> --json state,mergedAt
# require: all three report "state": "MERGED"
```

Then the same guarded branch sweep as Path 1.

Why `--merge` on the tip: the automatic MERGED detection needs the stack's
commits to become ancestors of the default branch. A squash or rebase merge
creates new commit objects, so the contained PRs' heads never become
ancestors and the auto-detection is not expected to fire (derived from git
semantics, untested).

## What NOT To Do

```bash
# WRONG: deletes step-1 while #102 still bases on it.
# Observed result (as of July 2026): #102 auto-closes without retargeting,
# and cannot be retargeted or reopened afterwards.
gh pr merge 101 --repo <owner>/<name> --merge --delete-branch
```

If you already did this, switch to the recovery template:
[auto-close-recovery-template.md](auto-close-recovery-template.md).
