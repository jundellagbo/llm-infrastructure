---
description: Ship a pull request for the current branch - gather state via git/gh, clear every blocker, then commit, push and open the PR directly. Never duplicates an existing PR.
---

<!-- infra-llm:generated -->
# Ship a pull request

Read the real state yourself first:
- current branch (`git branch --show-current`) and base (`git symbolic-ref --short refs/remotes/origin/HEAD`, else origin/main|master);
- `git status --short`; `git log --oneline <base>..HEAD` and `git diff --stat <base>...HEAD` for what's ahead;
- `gh pr view --json url,state,title,isDraft` — if a PR already exists, show its URL/status and STOP; never duplicate.

This command pushes for real, so clear every blocker before touching git:
- `infra-llm verify` must pass — a red tree is a blocker to fix or report, never something to push over;
- the diff must be coherent (it says what changed, not what was asked). Under ~30 changed files read it whole; above that work from `--stat` and read only the files the summary and risks turn on;
- if HEAD is on the base branch, the work needs its own branch first.

Then ship it yourself — the guard window is what makes the push allowed:
1. `infra-llm git-window pr`
2. `git switch -c <branch>` if still on base; `git add` the work; `git commit`
3. `git push -u origin <branch>`
4. `gh pr create --title "..." --body-file infra-llm/tmps/pr-body.md`
5. `infra-llm git-window --close`, then report the PR URL.

All scratch for this run — the body draft, anything temporary — goes in `infra-llm/tmps/` (git-ignored), never in `/tmp` or the project tree. No AI/LLM attribution anywhere: commit, title or body.

PR body — four sections readable in 30 seconds: **Summary** (what changed and why), **Testing** (what ran and its result), **Risks** (what to watch), **Rollback** (how to undo).
