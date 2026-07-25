---
description: Review the recent change - gather the diff via git, review by priority, verify each finding, apply confirmed fixes to the working tree (never commit).
---

<!-- infra-llm:generated -->
# Review the recent change

Scope it yourself (read-only git): review only the recent change, not the whole
repo. `git status --short` and `git diff HEAD` for uncommitted work; then
`git log --oneline <base>..HEAD` and `git diff <base>...HEAD` for committed work
on top of the base (origin/HEAD, else origin/main|master). If the user named
files, review those. Read the diff AND the surrounding code before judging.

Look, in priority order: **correctness** (wrong logic, bad edge/null handling,
swallowed errors, races, leaks, broken callers/contracts), **security**
(untrusted input reaching a sink, missing authn/authz, leaked secrets, weak
crypto, over-broad permissions, unpinned deps), **data safety** (destructive or
irreversible ops without a guard, lossy migrations), **implementation quality**
(duplication, wrong abstraction, dead code, fighting conventions) and
**tests/observability**. Match existing style — preference isn't a finding.

Verify each finding before acting; "no issues" is valid, and a wrong finding
costs more than it saves. Apply confirmed fixes minimal and targeted; refactor
only where genuinely needed, never style churn. Report what you **fixed**
(file:line, the defect, the failure scenario, the fix — worst first),
**refactored**, and **left alone**, then run `infra-llm verify`. Never commit or
push — fixes stay in the working tree.
