# Changelog

All notable changes to this project are documented in this file.

The format loosely follows Keep a Changelog conventions.

## Unreleased

## 0.1.0 - 2026-07-16

### Added

- Initial gh stacked-PR merge-order skill (`SKILL.md`): the safe merge
  order (merge without `--delete-branch`, confirm `MERGED`, retarget
  children with `gh pr edit --base`, resolve conflicts on the head branch,
  guarded final branch sweep), the retarget-first bulk landing
  alternative, supersedes-PR recovery for auto-closed PRs, the
  branch-protection timing trap (merge → confirm `MERGED` → only then
  delete), cherry-pick splitting of mixed stacks, and state-snapshot
  document conflict handling.
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
