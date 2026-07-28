---
description: Prepare a pull request for the current branch - gather state via git/gh, draft the PR, hand the git push/create to the user. Never duplicates an existing PR.
---

<!-- infra-llm:generated -->
# Prepare a pull request

Read the real state yourself first (read-only git is fine):
- current branch (`git branch --show-current`) and base (`git symbolic-ref --short refs/remotes/origin/HEAD`, else origin/main|master);
- `git status --short`; `git log --oneline <base>..HEAD` and `git diff --stat <base>...HEAD` for what's ahead;
- `gh pr view --json url,state,title,isDraft` — if a PR already exists, show its URL/status and STOP; never duplicate.

If HEAD is on the base branch, the work needs its own branch first. Read the
actual diff (it says what changed, not what was asked) and confirm it's coherent.
Under ~30 changed files read it whole; above that a full diff crowds out the rest
of the session, so work from `--stat` and read only the files the summary and
risks actually turn on. Run `infra-llm verify` and confirm it passes — flag a red
tree, don't hide it.

Git is the user's decision, so DON'T commit, push, branch or open the PR
yourself. Prepare everything, then hand over the exact commands to run
(`git switch -c <branch>` if needed, `git commit`, `git push -u origin <branch>`,
`gh pr create`) plus the PR body below. No AI/LLM attribution anywhere.

PR body — four sections readable in 30 seconds: **Summary** (what changed and
why), **Testing** (what ran and its result), **Risks** (what to watch),
**Rollback** (how to undo).
