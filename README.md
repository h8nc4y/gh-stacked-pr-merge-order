# gh-stacked-pr-merge-order

[![Validate](https://github.com/h8nc4y/gh-stacked-pr-merge-order/actions/workflows/validate.yml/badge.svg)](https://github.com/h8nc4y/gh-stacked-pr-merge-order/actions/workflows/validate.yml)

An agent skill for Claude Code and Codex: merge stacked pull requests
safely with the gh CLI — retarget children before deleting base branches,
confirm `MERGED` state before any branch deletion, and recover auto-closed
PRs with supersedes PRs.

## What It Solves

A stacked PR chain (#A ← #B ← #C, each child's base is the previous PR's
head branch) hides a one-command disaster: merging the bottom PR with
`gh pr merge --delete-branch` deletes the branch the next PR is based on,
and GitHub has been observed to **auto-close the descendants without
retargeting them** when the deletion comes through the gh CLI or API
(the web UI's delete button retargets them instead — observed as of July
2026; the behavior may change). An auto-closed PR is unrecoverable in
place:

- `gh pr edit <n> --base <default>` → `Cannot change the base branch of a
  closed pull request`
- `gh pr reopen <n>` → refused as well

So the skill is a prevention-first discipline, distilled from real
incidents and recoveries:

- **The safe merge order** — merge without `--delete-branch`, confirm
  `MERGED`, retarget the next PR with `gh pr edit --base`, resolve
  conflicts on the head branch, repeat; delete all head branches only
  after the whole stack reports `MERGED`.
- **A retarget-first bulk landing alternative** — retarget every PR to the
  default branch first, merge only the tip, and GitHub marks the contained
  PRs `MERGED` automatically.
- **The branch-protection timing trap** — a merge attempted before
  required checks complete fails quietly in scripted flows, and the branch
  deletion that follows auto-closes the still-open PR. Always: merge →
  confirm `MERGED` → only then delete.
- **Supersedes recovery** — when a PR was auto-closed anyway, open a new
  PR from the same head branch with `Supersedes #<n>` in the body.
- **Cherry-pick splitting** — when a stacked docs PR turns out to carry
  unrelated feature commits, cherry-pick the commits that belong into a
  fresh PR and close the old one as superseded.
- **State-snapshot document conflicts** — handoff-style documents conflict
  at every stack layer; take the newer side and sync once in a final
  docs-only PR.

## Who It Is For

- Claude Code and Codex users whose agents land multi-PR stacks with the
  gh CLI.
- Anyone scripting `gh pr merge` automation who wants the auto-close
  failure mode documented before hitting it.
- Humans who just lost half a stack to `--delete-branch` and need the
  recovery path.

## Install

Clone the repository:

```bash
git clone https://github.com/h8nc4y/gh-stacked-pr-merge-order.git
cd gh-stacked-pr-merge-order
```

### Claude Code

Claude Code auto-invokes the skill when a task matches the `description`
frontmatter. Install for your user account on shells with POSIX syntax:

```bash
dest="${HOME}/.claude/skills/gh-stacked-pr-merge-order"
if [ -e "$dest" ]; then
  echo "Install target already exists: $dest"
else
  mkdir -p "$dest"
  cp SKILL.md "$dest/SKILL.md"
fi
```

Install for your user account from PowerShell:

```powershell
$dest = Join-Path $HOME '.claude\skills\gh-stacked-pr-merge-order'
if (Test-Path -LiteralPath $dest) {
  throw "Install target already exists: $dest"
}
New-Item -ItemType Directory -Path $dest | Out-Null
Copy-Item -LiteralPath .\SKILL.md -Destination (Join-Path $dest 'SKILL.md')
```

Notes:

- If you set `CLAUDE_CONFIG_DIR`, replace `~/.claude` with that directory.
- To scope the skill to a single project instead, copy `SKILL.md` to
  `.claude/skills/gh-stacked-pr-merge-order/SKILL.md` inside that
  project's repository.

The existence guard is intentional: do not overwrite an already-installed
skill without reviewing the local copy first.

### Codex (agent skills)

Manual Codex-style skill install on shells with POSIX syntax:

```bash
dest="${HOME}/.agents/skills/gh-stacked-pr-merge-order"
if [ -e "$dest" ]; then
  echo "Install target already exists: $dest"
else
  mkdir -p "$dest"
  cp SKILL.md "$dest/SKILL.md"
fi
```

Manual Codex-style skill install from PowerShell:

```powershell
$dest = Join-Path $HOME '.agents\skills\gh-stacked-pr-merge-order'
if (Test-Path -LiteralPath $dest) {
  throw "Install target already exists: $dest"
}
New-Item -ItemType Directory -Path $dest | Out-Null
Copy-Item -LiteralPath .\SKILL.md -Destination (Join-Path $dest 'SKILL.md')
```

To scope the skill to a single project instead, copy `SKILL.md` to
`.agents/skills/gh-stacked-pr-merge-order/SKILL.md` inside that repository
— Codex scans `.agents/skills` from the working directory up to the
repository root (per the official skills documentation).

If your agent reads skills from a different directory, check its
documentation and copy `SKILL.md` into the matching
`skills/gh-stacked-pr-merge-order/` folder.

## Manual Use

Reach for the skill when you see one of these symptoms:

- A child PR closed itself the moment its base branch was deleted.
- `gh pr edit <n> --base <default>` fails with `Cannot change the base
  branch of a closed pull request`.
- `gh pr reopen <n>` fails on a PR GitHub closed automatically.
- You are about to land a stack of PRs with the gh CLI and want the order
  that avoids the above.
- On a branch-protected repository, a merge "ran" but the PR ended up
  closed instead of merged after a branch deletion.
- A stacked docs PR turns out to contain unrelated feature commits.

Follow the procedure in [SKILL.md](SKILL.md): merge the bottom PR without
`--delete-branch`, confirm `MERGED`, retarget the next PR, resolve
conflicts on its head branch, repeat up the stack, and delete head
branches only in one final guarded sweep.

## Synthetic Examples

- [Three-PR stack walkthrough](examples/three-pr-stack-walkthrough.md) —
  every command for landing a three-PR stack, both the sequential safe
  order and the retarget-first bulk landing.
- [Auto-close recovery template](examples/auto-close-recovery-template.md)
  — identify auto-closed PRs and open supersedes PRs, with a ready-to-fill
  body template.
- [Pre-merge checklist](examples/pre-merge-checklist.md) — what to verify
  before the first merge command of a stack integration.

The examples use placeholders and synthetic PR numbers only. Do not
replace them with secrets, real repository paths you cannot publish, or
customer data in public issues.

## Live Verification

The sequential safe order and the retarget-first bulk landing were
reproduced end-to-end on this repository itself: a three-PR stack and a
two-PR stack, created, landed, and swept with the skill's own guards,
with zero auto-closed PRs. The command-level log with timestamps is in
[docs/VERIFICATION.md](docs/VERIFICATION.md).

## Related Skill

[isolated-worktree-pr-flow](https://github.com/h8nc4y/isolated-worktree-pr-flow)
is the complementary skill: it covers shipping a *single* PR from a
temporary worktree when the main checkout is dirty or shared. This skill
covers landing a *stack* of PRs in the right order. They compose: create
each PR with the worktree flow, land the stack with this one.

## 日本語概要 (Japanese Overview)

stacked PR（#A ← #B ← #C と base が連鎖する PR）を gh CLI で統合するとき、
子 PR を auto-close させないための手順です。核心: gh CLI / API 経由で base
branch を削除すると子 PR が retarget されず close されることがある（Web UI
の削除は retarget される — 2026年7月時点の観測）。close された PR は base
変更も reopen も不可能なので、予防が全てです。

- 安全な順序: 親を `--delete-branch` なしで merge → `MERGED` 確認 → 子を
  `gh pr edit --base` で retarget → 衝突は head branch 側で解消 → merge。
  branch 削除は全 PR が `MERGED` になってから最後にまとめて。
- 代替: 全 PR を先に default branch へ retarget → tip だけ merge →
  GitHub が包含 PR を自動 `MERGED` 判定。
- branch protection の罠: CI 完了前の merge は静かに失敗し、続く branch
  削除で PR が auto-close する。「merge → `MERGED` 確認 → 削除」を厳守。
- 復旧: auto-close された PR は reopen 不可。同じ head branch から
  `Supersedes #<n>` を本文に書いた新 PR を作る。
- 混成スタック: 必要な commit だけ cherry-pick → 新 PR → 旧 PR を
  superseded として close。

安全な順序と一括着地は、本リポジトリ自身の3段/2段ミニスタックで実地
再現済みです（auto-close ゼロ。コマンドレベルの記録は
[docs/VERIFICATION.md](docs/VERIFICATION.md)）。

日本語の完全版は [docs/SKILL.ja.md](docs/SKILL.ja.md) にあります。
インストールは上記の手順どおり、`SKILL.md` を Claude Code なら
`~/.claude/skills/gh-stacked-pr-merge-order/` へ、Codex なら
`~/.agents/skills/gh-stacked-pr-merge-order/` へコピーしてください。
単発 PR の作り方は補完 skill の
[isolated-worktree-pr-flow](https://github.com/h8nc4y/isolated-worktree-pr-flow)
を参照。

## Safety Notes

- Never delete a branch while any open PR still uses it as base or head —
  check with `gh pr list --base <branch> --state open` and
  `gh pr list --head <branch> --state open` first.
- `--delete-branch` is banned inside a stack, including combined with
  `--auto`.
- After every merge, confirm `"state": "MERGED"` before the next mutation;
  never batch "merge; delete" without the state check between them.
- Never paste tokens, credentials, private logs, or customer data into PR
  bodies, commit messages, or public issues.

## Limitations

- The GitHub behaviors this skill works around (CLI/API deletion closing
  descendants without retargeting; web-UI deletion retargeting them;
  automatic MERGED detection after a bulk landing) are observations as of
  July 2026, not documented contracts. Re-verify before depending on them;
  they may change without notice.
- The retarget-first bulk landing is expected to require a merge commit on
  the tip; under `--squash` / `--rebase` the contained PRs' commits never
  become ancestors of the default branch, so auto-detection is not
  expected there (derived from git semantics, untested).
- Interaction with merge queues is untested.
- The flow assumes `git` and the GitHub CLI (`gh`); other forges need
  equivalent commands for PR state, retargeting, and branch deletion.

## Non-Goals

- No automation scripts that run the flow for you. This repository is a
  written discipline with copy-adaptable commands, not a tool.
- No general stacked-diff tooling comparison (Graphite, spr, jj, and
  friends); the focus is landing an existing gh-CLI stack safely.

## Validation

Run the full local validation from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
```

If `pwsh` is available, the same checks can be run with:

```powershell
pwsh -NoProfile -File .\scripts\validate-oss-readiness.ps1
pwsh -NoProfile -File .\scripts\test-scan-private-markers.ps1
pwsh -NoProfile -File .\scripts\scan-private-markers.ps1
```

On macOS, Linux, or any POSIX shell with PowerShell 7 (`pwsh`) installed:

```bash
pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1
pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1
pwsh -NoProfile -File ./scripts/scan-private-markers.ps1
```

Bounded POSIX child cleanup uses the system `setsid` executable when
available and a same-host `libc` `setsid(2)` gate otherwise. The self-test
forces the fallback path, so macOS does not require an extra `setsid`
package merely to run the scanner.

Also run Git whitespace checks on your working changes before publishing:

```bash
git diff --check
```

The GitHub Actions workflow runs the same validation, scan self-test,
private-marker scan, and committed-tree whitespace check on both Windows
and Ubuntu for pull requests and pushes to `main`. The Windows job runs
the checks under both PowerShell 7 and Windows PowerShell 5.1. Each matrix
job has a 25-minute timeout. Scanner PowerShell sources use UTF-8 with BOM,
and readiness validation checks the actual byte prefix as well as the
repository editor policy.

The scanner's hermetic boundary, finite budgets, fail-closed states, and
portable process cleanup contract are specified in
[docs/SCANNER-HARDENING.md](docs/SCANNER-HARDENING.md).

## Contributing

Contributions are welcome when they make the merge order safer, clearer,
or easier to verify. Read [CONTRIBUTING.md](CONTRIBUTING.md) before
opening a pull request.

Keep all examples synthetic. Do not include tokens, credentials, private
repository names, internal absolute paths, or customer data.

For local-only private markers, create an untracked
`.private-markers.local` file with one literal marker per line, or set
`GH_STACKED_PR_MERGE_ORDER_PRIVATE_MARKERS` with newline-separated
markers. The scanner reads these values but does not print the matched
marker.

## Security

If you find unsafe guidance or accidental private-data exposure, follow
[SECURITY.md](SECURITY.md) and use private reporting for sensitive
details.

## License

MIT. See [LICENSE](LICENSE).
