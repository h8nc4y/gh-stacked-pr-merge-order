# Security Policy

This repository documents a stacked-PR merge workflow. It should never
contain secrets, but its guidance drives agents through destructive
GitHub operations (merging PRs, retargeting them, deleting branches), so
unsafe guidance is treated as a security problem too.

## Supported Versions

The `main` branch is the supported version. Tagged releases receive fixes
through new tags on `main`.

## Reporting A Vulnerability

Use GitHub private vulnerability reporting for:

- A real secret, credential, or private identifier accidentally committed
  to this repository.
- Guidance that could cause agents to destroy user work (for example a
  merge-order step that deletes a branch while PRs still depend on it, or
  a recovery step that loses commits), leak private data, or run
  destructive commands outside the flow's scope.
- A validation gap that allows unsafe public examples.

Do not open a public issue containing tokens, credentials, private keys,
OAuth material, customer data, raw secret-bearing logs, or private
repository names and internal paths.

## Public Issue Safety

Public issues may include:

- Symptom class, such as "child PR auto-closed on branch deletion" or
  "bulk landing did not mark contained PRs merged".
- Sanitized command classes, such as `gh pr view` state values or
  `gh pr edit --base` refusals, without private paths.
- Placeholder repository, branch, and PR identifiers.

Public issues must not include:

- Secret values or secret-display command output.
- Private repository names, internal absolute paths, hostnames, or
  customer data.
- Raw agent transcripts that contain any of the above.

## Scanner Coverage

The private-marker scanner (`scripts/scan-private-markers.ps1`) is a
best-effort safety net, not a guarantee. For git-tracked text paths, it
scans both the exact index blob and a distinct current regular worktree
snapshot. It reads intent-to-add from the index extended flags and
rechecks raw stage/debug metadata immediately before reporting. It does
not follow worktree links or fetch missing Git objects; ambiguous index,
root, link, encoding, process, drift, count, or size states fail closed.
File, entry, line, regex-match, finding, byte, process, output, and time
budgets bound hostile input.

The scanner checks a curated set of secret prefixes (GitHub, OpenAI, AWS,
GCP, Slack, Stripe, PEM key blocks, and similar), private-looking
absolute Windows paths, non-allowlisted GitHub repository URLs, and
configured local markers, and it redacts any matched value. Only this
repository and its documented `isolated-worktree-pr-flow` companion are
allowlisted GitHub repository URLs. `.private-markers.local` must remain
untracked. The scanner does not detect every possible secret format and
is no substitute for keeping real credentials out of the repository in
the first place. Treat a passing scan as "no known marker found," not
"definitely safe."

## Response Expectations

Maintainers should acknowledge actionable security reports when
available, remove or redact unsafe public material, and prefer guidance
that reduces data-exposure and work-destruction risk. If real exposure is
possible, rotate the affected secret outside this public repository and
document only the remediation status.
