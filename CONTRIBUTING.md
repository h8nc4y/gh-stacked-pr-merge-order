# Contributing

Thanks for improving this skill. This repository is intentionally small:
changes should make the stacked-PR merge order safer, clearer, or easier
to verify.

## Before You Start

- Read [SKILL.md](SKILL.md) and the examples under [examples](examples).
- `SKILL.md` (English) is canonical. When you change it, update
  [docs/SKILL.ja.md](docs/SKILL.ja.md) in the same pull request so the two
  stay in sync.
- Do not paste tokens, credentials, private keys, OAuth codes, raw logs,
  customer data, private repository names, or internal absolute paths into
  issues, pull requests, commits, or examples. No token or secret value
  ever belongs in this repository.
- Use synthetic placeholders such as `<owner>/<name>`, `<default>`,
  `<head-branch>`, and `<n>` — or clearly-labeled synthetic PR numbers —
  for examples.
- Put personal or organization-specific scan markers in an untracked
  `.private-markers.local` file, not in repository source.

## Grounding Rules

This skill's value is that every rule traces to observed behavior. Keep it
that way:

- Claims about GitHub platform behavior must be dated observations
  ("observed as of July 2026"), never timeless facts — GitHub can change
  the behavior without notice. If you re-verify a behavior at a later
  date, update the observation date in the same change.
- Mark speculation and semantics-derived-but-unvalidated guidance
  explicitly as untested — the bulk-landing behavior under squash/rebase
  is the existing example of how to phrase this.
- Do not remove existing honesty markers ("field-tested", "observed as
  of", "untested") without evidence that changes their status.

## Development Workflow

1. Create a focused branch.
2. Make the smallest coherent change.
3. Update examples or README text when user-facing guidance changes.
4. Add or adjust validation when a safety rule should be machine-checkable.
5. Run the validation commands before opening a pull request.

## Validation

From the repository root, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
git diff --check
```

If `pwsh` is available, it is also acceptable for the PowerShell scripts:

```powershell
pwsh -NoProfile -File .\scripts\validate-oss-readiness.ps1
pwsh -NoProfile -File .\scripts\test-scan-private-markers.ps1
pwsh -NoProfile -File .\scripts\scan-private-markers.ps1
```

On macOS, Linux, or any POSIX shell with PowerShell 7 (`pwsh`) installed,
use forward slashes:

```bash
pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1
pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1
pwsh -NoProfile -File ./scripts/scan-private-markers.ps1
```

## Pull Request Expectations

- Explain the problem and the chosen fix.
- Include validation results.
- Call out any remaining unknowns.
- If the change alters a merge-order rule, a guard, or a recovery path,
  describe the failure mode it prevents (or the false refusal it removes)
  concretely.

## Maintainer Notes

Prefer documentation and validation that prevent PR-destroying accidents
(auto-closed stacks, branches deleted under open PRs). Avoid adding broad
dependencies or network-backed checks unless they are clearly necessary
for public safety.
