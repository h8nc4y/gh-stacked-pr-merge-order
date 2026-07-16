# Auto-Close Recovery Template — Supersedes PR

Synthetic example. `<owner>/<name>`, `#102`, and `step-2` are placeholders.

Use this when a stacked PR was auto-closed because its base branch was
deleted through the gh CLI or API. Reopening is not possible; the recovery
is a new PR from the same head branch.

## 1. Confirm what actually happened

```bash
gh pr view 102 --repo <owner>/<name> --json state,mergedAt,headRefName,baseRefName
```

- `"state": "CLOSED"` with `"mergedAt": null` → closed without merging:
  this template applies.
- `"state": "MERGED"` → nothing was lost; stop here.

Confirm the two dead ends, so nobody retries them later (both refusals are
field-tested):

```bash
gh pr edit 102 --repo <owner>/<name> --base main
# refused: "Cannot change the base branch of a closed pull request"
gh pr reopen 102 --repo <owner>/<name>
# refused as well for PRs GitHub auto-closed this way
```

## 2. Verify the head branch still exists

Only the base branch was deleted; the head branch normally survives:

```bash
git ls-remote --heads origin step-2   # must print a ref
```

If the head branch is gone too, restore it first from a local clone or
reflog before continuing.

## 3. Create the supersedes PR

Write the body to a file (multi-line bodies are fragile inline,
especially on Windows):

```bash
gh pr create --repo <owner>/<name> \
  --head step-2 \
  --base main \
  --title "<original title>" \
  --body-file recovery-body.md
```

`recovery-body.md` template — fill the angle-bracket slots:

```markdown
Supersedes #<closed-number>.

<original PR body, copied or re-summarized>

## Recovery note

#<closed-number> was auto-closed when its base branch
`<deleted-base-branch>` was deleted during a stack integration
(gh CLI / API branch deletion does not retarget descendant PRs —
observed as of July 2026). This PR re-lands the same head branch
`<head-branch>` onto `<default>`. No commits were changed.
```

The `Supersedes #<n>` line is the important part: GitHub links the two
PRs, so anyone landing on the closed PR finds the successor.

## 4. Land it safely

- Review approvals did not carry over; re-request them if required.
- Merge with the safe order from
  [SKILL.md](../SKILL.md): merge without `--delete-branch`, confirm
  `"state": "MERGED"`, and delete branches only in the final sweep.
