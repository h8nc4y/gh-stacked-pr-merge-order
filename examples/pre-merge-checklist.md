# Pre-Merge Checklist — Before The First Merge Command Of A Stack

Run through this once, before touching the first PR of a stack
integration. Placeholders throughout; nothing refers to a real repository.

## Map the stack

- [ ] List the open PRs and their base/head pairs:

  ```bash
  gh pr list --repo <owner>/<name> --state open \
    --json number,title,baseRefName,headRefName
  ```

- [ ] Draw the chain (#A ← #B ← #C …) from the base/head pairs. Every PR
  whose base is another PR's head is part of the stack.
- [ ] Identify the tip (the PR no other PR bases on) and the bottom (the
  PR based on the default branch).

## Know the repository

- [ ] Default branch confirmed, not assumed:

  ```bash
  gh repo view <owner>/<name> --json defaultBranchRef -q .defaultBranchRef.name
  ```

- [ ] Branch protection / required checks known. If checks are required,
  plan for: bounded polling with `gh pr checks <n> --watch=false`, or
  `gh pr merge --auto` (never with `--delete-branch` in a stack), and a
  `MERGED`-state check after every merge.
- [ ] Auto-delete setting checked:

  ```bash
  gh repo view <owner>/<name> --json deleteBranchOnMerge
  ```

  If `true`, the server deletes each head branch as its PR merges, even
  without `--delete-branch`. Retarget all descendants before the first
  merge (bulk-landing order) or temporarily disable the setting for the
  integration; what happens to descendant PRs under auto-delete is
  untested.
- [ ] Merge mode decided (`--merge` / `--squash` / `--rebase`). For the
  retarget-first bulk landing, the tip needs `--merge` (squash/rebase are
  not expected to trigger the automatic MERGED detection — untested).

## Decide the path

- [ ] Sequential safe order (default), or retarget-first bulk landing
  (purely additive stacks, one CI run)?
- [ ] For each PR: does anything else base on its head branch?

  ```bash
  gh pr list --repo <owner>/<name> --base <head-branch> --state open
  ```

## Commit hygiene

- [ ] No unrelated commits mixed into the stack. If a docs stack carries
  feature commits (or the reverse), split first: cherry-pick the commits
  that belong onto a fresh branch, open a new PR, close the old one as
  `Superseded by #<new>`.
- [ ] State-snapshot documents (handoff notes, task backlogs) identified.
  Expect them to conflict at each layer; resolve by taking the newer side
  and plan one docs-only sync PR after the stack lands.

## Safety rails armed

- [ ] `--delete-branch` will not be used anywhere in this integration.
- [ ] After every merge: `gh pr view <n> --json state,mergedAt` must show
  `MERGED` before the next mutation.
- [ ] Branch deletion happens once, at the end, only after every PR
  reports `MERGED` and, for every branch, both
  `gh pr list --base <branch> --state open` and
  `gh pr list --head <branch> --state open` come back empty.
- [ ] If a PR does get auto-closed: no `edit --base` / `reopen` retries —
  go straight to the
  [supersedes recovery](auto-close-recovery-template.md).
