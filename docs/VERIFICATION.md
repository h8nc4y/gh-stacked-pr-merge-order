# Live Verification Log

This file is built by stacked pull requests on this repository itself,
landed with the skill's own safe merge order. Each list item below was
added by one layer of a verification stack; the results section at the
end records how the landing went.

## Stack layers

- Stack A, layer 1 (base: default branch)
- Stack A, layer 2 (base: layer 1's head branch)
- Stack A, layer 3 (base: layer 2's head branch)
- Stack B, layer 1 (base: default branch; landed via retarget-first bulk landing)
- Stack B, layer 2 (tip; merged with a merge commit)

## Results

Verified live on this repository, 2026-07-16 (UTC), with gh 2.92.0. This
repository had no branch protection at verification time, and the stack
layers were purely additive appends to this file. Timestamps are from
`gh pr view --json mergedAt`.

### Stack A — sequential safe order (#2 ← #3 ← #4)

- #2 merged with `--merge` and **no** `--delete-branch` → `MERGED` at
  06:28:42Z; #3 stayed `OPEN` on its surviving base branch.
- #3 retargeted to the default branch (`mergeable: MERGEABLE`,
  `mergeStateStatus: CLEAN`), merged → `MERGED` at 06:29:14Z.
- #4 the same: retarget → `MERGEABLE` / `CLEAN` → merged → `MERGED` at
  06:29:33Z.
- Guarded sweep: `gh pr list --base <branch> --state open` and
  `gh pr list --head <branch> --state open` both empty for all three
  branches, then one `git push origin --delete` sweep.
- Auto-closed PRs: zero.

### Stack B — retarget-first bulk landing (#5 ← #6)

- #6 (tip) retargeted to the default branch, then merged with a merge
  commit → `MERGED` at 06:31:15Z.
- #5 was marked `MERGED` automatically at 06:31:16Z — one second later,
  with no merge command issued against it. The bulk-landing observation
  reproduced.

### Fresh observation

- `mergeable` can report `UNKNOWN` immediately after a retarget while
  GitHub recomputes it asynchronously. Re-poll until it settles to
  `MERGEABLE` or `CONFLICTING` before acting on it.
