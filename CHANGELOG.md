# Changelog

All notable changes to this project are documented in this file.

The format loosely follows Keep a Changelog conventions.

## Unreleased

### Added

- Live verification log (`docs/VERIFICATION.md`): the sequential safe
  order and the retarget-first bulk landing reproduced end-to-end on this
  repository itself (a three-PR stack and a two-PR stack, zero
  auto-closed PRs), plus a README pointer.
- Safe merge order note: `mergeable` may report `UNKNOWN` immediately
  after a retarget while GitHub recomputes it asynchronously; re-poll
  before acting on it.

### Fixed

- Preserve Git's forward-slash paths while resolving tracked nested files
  on Windows and POSIX, and include hidden/dotfile candidates in both
  repository and fallback scans.
- Scan both the exact index blob and the distinct regular worktree
  snapshot, including staged-only, unstaged-only, missing, and
  intent-to-add states. Ambiguous conflict, gitlink, symlink, reparse,
  index-drift, and repository-root states now fail closed.

### Changed

- Isolate scanner Git children from known, unknown, populated, and
  present-empty ambient `GIT_*` variables plus hooks, filters, attributes,
  replace objects, transports, and lazy object fetching.
- Bound filesystem entries, paths, scan targets, bytes, lines, regex
  matches, findings, Git processes, stdout/stderr, and total runtime.
  Displayed paths escape control, bidi/format, and logical line-separator
  characters; serialized reports include their prefix and actual OS
  newline within the byte cap.
- Read index blobs through one bounded `git cat-file --batch` stream and
  recheck byte-identical raw stage/debug metadata after matching.
- Add atomic Windows Job containment through a suspended `CreateProcessW`
  child and a limited inherited-handle list, plus POSIX process-group
  containment with errno-aware cleanup and synthetic immediate-descendant
  race coverage. Assignment/resume failure tests also prove the suspended
  target PID disappears within the cleanup deadline.
- Scan `.env` variants, PEM/key/certificate files, `.npmrc`, single-dot
  hidden names, and extensionless text candidates. Preserve exactly the
  two documented GitHub URL allowlist entries for this repository and
  `isolated-worktree-pr-flow`.
- Run validation on both Windows and Ubuntu in CI; the Windows job also
  exercises Windows PowerShell 5.1. Pin the checkout action to an immutable
  commit revision and enforce UTF-8 BOM bytes for PowerShell sources.

## 0.1.0 - 2026-07-16

### Added

- Initial gh stacked-PR merge-order skill (`SKILL.md`): the safe merge
  order (merge without `--delete-branch`, confirm `MERGED`, retarget
  children with `gh pr edit --base`, resolve conflicts on the head branch,
  guarded final branch sweep checking both base and head dependents, and a
  `deleteBranchOnMerge` pre-check), the retarget-first bulk landing
  alternative, supersedes-PR recovery for auto-closed PRs with
  head-branch-survival verification, the branch-protection timing trap
  (merge → confirm `MERGED` → only then delete), cherry-pick splitting of
  mixed stacks, and state-snapshot document conflict handling.
- Japanese full version of the skill (`docs/SKILL.ja.md`).
- Synthetic examples: three-PR stack walkthrough (sequential and bulk
  landing), auto-close recovery template with a supersedes PR body
  template, and a pre-merge checklist.
- Private-marker scan for common secret prefixes, private-looking absolute
  paths, and non-allowlisted GitHub repository URLs, with a self-test and
  local marker support through `.private-markers.local` or the
  `GH_STACKED_PR_MERGE_ORDER_PRIVATE_MARKERS` environment variable.
- OSS readiness validation script for required public project files and
  skill frontmatter.
- GitHub Actions workflow for validation, private-marker scanning, and
  whitespace checks.
- Issue and pull request templates with sanitized-report guidance.
- Contributor, security, code of conduct, editor, and Git attribute
  documentation.
